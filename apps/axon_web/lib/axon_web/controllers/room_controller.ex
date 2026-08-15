defmodule AxonWeb.RoomController do
  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, Repo}
  alias AxonRoom.{AuthRules, CreateRoom, EventBuilder, RestrictedJoin, RoomProcess, RoomUpgrade}
  alias AxonSync.Typing

  # POST /_matrix/client/v3/createRoom
  def create(conn, params) do
    user_id = conn.assigns.current_user_id
    server_name = Application.fetch_env!(:axon_web, :server_name)

    # Validate room_version type — must be string if present
    if Map.has_key?(params, "room_version") and not is_binary(params["room_version"]) do
      conn
      |> put_status(400)
      |> json(%{"errcode" => "M_BAD_JSON", "error" => "room_version must be a string"})
    else
      opts = [
        server_name: server_name,
        name: params["name"],
        topic: params["topic"],
        preset: params["preset"],
        is_direct: params["is_direct"],
        invite: params["invite"] || [],
        room_alias_name: params["room_alias_name"],
        version: params["room_version"],
        creation_content: params["creation_content"],
        initial_state: params["initial_state"] || [],
        visibility: params["visibility"],
        power_level_content_override: params["power_level_content_override"]
      ]

      with {:ok, room_id} <- CreateRoom.execute(user_id, opts) do
        json(conn, %{"room_id" => room_id})
      else
        # These two power_level_content_override validation failures don't
        # have a fallback_controller.ex mapping (out of this file's
        # ownership) — handled directly here rather than adding one.
        {:error, :power_levels_may_not_list_creators} ->
          conn
          |> put_status(400)
          |> json(%{
            "errcode" => "M_BAD_JSON",
            "error" =>
              "power_level_content_override may not list the room's creator(s) in users (room v12+)"
          })

        {:error, :power_level_content_override_excludes_creator} ->
          conn
          |> put_status(400)
          |> json(%{
            "errcode" => "M_BAD_JSON",
            "error" => "power_level_content_override.users must include the room creator"
          })

        {:error, :invalid_power_level_content_override} ->
          conn
          |> put_status(400)
          |> json(%{
            "errcode" => "M_BAD_JSON",
            "error" => "power_level_content_override must be an object"
          })

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # GET /_matrix/client/v3/joined_rooms
  def joined_rooms(conn, _params) do
    user_id = conn.assigns.current_user_id
    rooms = EventStore.get_joined_rooms(user_id)
    json(conn, %{"joined_rooms" => rooms})
  end

  # POST /_matrix/client/v3/join/:room_id_or_alias
  # POST /_matrix/client/v3/rooms/:room_id/join
  def join(conn, %{"room_id" => room_id_or_alias} = params) do
    user_id = conn.assigns.current_user_id
    local_server = Application.get_env(:axon_web, :server_name, "localhost")
    server_params = server_name_hints(conn)

    # Resolve alias to room_id (local lookup first, then federation)
    {room_id, hint_servers} = resolve_room(room_id_or_alias, local_server, server_params)

    if is_nil(room_id) do
      conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found"})
    else
      room_server = room_id |> AxonCore.MatrixId.server_name()
      is_local_room = room_server == local_server or EventStore.room_exists?(room_id)

      if is_local_room do
        # Local room join
        with {:ok, _} <- EventStore.get_room(room_id),
             {:ok, content} <- build_join_content(room_id, user_id, params),
             {:ok, _event_id} <-
               RoomProcess.send_event(room_id, user_id, "m.room.member", content,
                 state_key: user_id
               ) do
          json(conn, %{"room_id" => room_id})
        end
      else
        # Remote room — use federation join flow
        case resolve_via_servers(room_id, room_server, hint_servers) do
          {:error, :missing_via_hint} ->
            conn
            |> put_status(400)
            |> json(%{
              "errcode" => "M_MISSING_PARAM",
              "error" =>
                "This room's ID has no server name (room version 12+); a via/server_name hint is required to join it"
            })

          {:ok, via_servers} ->
            case AxonFederation.RoomJoin.join_via_federation(room_id, user_id, via_servers) do
              {:ok, _} ->
                json(conn, %{"room_id" => room_id})

              {:error, reason} ->
                conn
                |> put_status(403)
                |> json(%{
                  "errcode" => "M_FORBIDDEN",
                  "error" => "Could not join room: #{inspect(reason)}"
                })
            end
        end
      end
    end
  end

  # A pre-v12 room's own id doubles as a routable server hint (the part
  # after the colon) when the caller gave none. A v12+ room_id has no
  # domain component at all, so `AxonCore.MatrixId.server_name/1` returns
  # nil for one — and federating to a nil (or, before that helper existed,
  # to the whole room_id string) as if it were a hostname would silently
  # fail with a bad DNS lookup instead of explaining what's missing.
  defp resolve_via_servers(_room_id, _room_server, hint_servers) when hint_servers != [],
    do: {:ok, hint_servers}

  defp resolve_via_servers(_room_id, nil, []), do: {:error, :missing_via_hint}
  defp resolve_via_servers(_room_id, room_server, []), do: {:ok, [room_server]}

  # POST /_matrix/client/v1/knock/:room_id_or_alias
  # POST /_matrix/client/v1/rooms/:room_id/knock
  def knock(conn, %{"room_id_or_alias" => room_id_or_alias} = params) do
    do_knock(conn, room_id_or_alias, params)
  end

  def knock(conn, %{"room_id" => room_id} = params) do
    do_knock(conn, room_id, params)
  end

  defp do_knock(conn, room_id_or_alias, params) do
    user_id = conn.assigns.current_user_id
    local_server = Application.get_env(:axon_web, :server_name, "localhost")
    server_params = server_name_hints(conn)

    {room_id, hint_servers} = resolve_room(room_id_or_alias, local_server, server_params)

    if is_nil(room_id) do
      conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found"})
    else
      room_server = room_id |> AxonCore.MatrixId.server_name()
      is_local_room = room_server == local_server or EventStore.room_exists?(room_id)
      reason = params["reason"]

      content =
        if reason,
          do: %{"membership" => "knock", "reason" => reason},
          else: %{"membership" => "knock"}

      if is_local_room do
        with {:ok, _event_id} <-
               RoomProcess.send_event(room_id, user_id, "m.room.member", content,
                 state_key: user_id
               ) do
          EventStore.set_knock_preview_state(
            room_id,
            user_id,
            AxonWeb.SyncHelpers.preview_state_events(room_id)
          )

          json(conn, %{"room_id" => room_id})
        end
      else
        case resolve_via_servers(room_id, room_server, hint_servers) do
          {:error, :missing_via_hint} ->
            conn
            |> put_status(400)
            |> json(%{
              "errcode" => "M_MISSING_PARAM",
              "error" =>
                "This room's ID has no server name (room version 12+); a via/server_name hint is required to knock on it"
            })

          {:ok, via_servers} ->
            case AxonFederation.RoomKnock.knock_via_federation(
                   room_id,
                   user_id,
                   via_servers,
                   reason
                 ) do
              {:ok, _} ->
                json(conn, %{"room_id" => room_id})

              {:error, reason} ->
                conn
                |> put_status(403)
                |> json(%{
                  "errcode" => "M_FORBIDDEN",
                  "error" => "Could not knock on room: #{inspect(reason)}"
                })
            end
        end
      end
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/leave
  #
  # A room this server is actually resident in (has a create event/full
  # state — true for any room we've ever joined, or created, or been
  # invited to *by a local user*) leaves through the normal local
  # RoomProcess path, same as always. A room known only via a *federated*
  # invite (AxonWeb.FederationController.invite/2 persists just the bare
  # membership row, deliberately not becoming resident) has no local
  # RoomProcess to send through at all — rejecting it has to go out via
  # make_leave/send_leave against the inviting server instead, exactly
  # like a federated join. Previously this endpoint only had the resident
  # path, so rejecting a federated invite silently did nothing but locally
  # discard the invite (the inviting server, and anyone else in the room,
  # never learned about the rejection).
  def leave(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.current_user_id

    cond do
      still_invited_to_server_notice_room?(room_id, user_id) ->
        conn
        |> put_status(403)
        |> json(%{
          "errcode" => "M_CANNOT_LEAVE_SERVER_NOTICE_ROOM",
          "error" => "You cannot reject this invite"
        })

      resident_room?(room_id) ->
        with {:ok, _event_id} <-
               RoomProcess.send_event(
                 room_id,
                 user_id,
                 "m.room.member",
                 %{"membership" => "leave"},
                 state_key: user_id
               ) do
          json(conn, %{})
        end

      true ->
        with {:ok, via_server} <- invite_sender_server(room_id, user_id),
             :ok <- AxonFederation.RoomLeave.leave_via_federation(room_id, user_id, [via_server]) do
          json(conn, %{})
        else
          _ -> {:error, :remote_leave_failed}
        end
    end
  end

  defp still_invited_to_server_notice_room?(room_id, user_id) do
    Repo.exists?(
      from(r in "server_notice_rooms",
        where: r.room_id == ^room_id and r.user_id == ^user_id
      )
    ) and
      Repo.one(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.user_id == ^user_id,
          select: m.membership
        )
      ) == "invite"
  end

  defp resident_room?(room_id) do
    match?({:ok, _}, EventStore.get_state_event(room_id, "m.room.create", ""))
  end

  defp invite_sender_server(room_id, user_id) do
    case EventStore.get_state_event(room_id, "m.room.member", user_id) do
      {:ok, %{sender: sender}} -> {:ok, sender |> AxonCore.MatrixId.server_name()}
      _ -> {:error, :no_invite_found}
    end
  end

  # PUT /_matrix/client/v3/rooms/:room_id/typing/:user_id
  def typing(conn, %{"room_id" => room_id, "user_id" => user_id} = params) do
    current_user_id = conn.assigns.current_user_id

    cond do
      user_id != current_user_id ->
        conn
        |> put_status(403)
        |> json(%{
          "errcode" => "M_FORBIDDEN",
          "error" => "Cannot set another user's typing state"
        })

      not joined?(room_id, current_user_id) ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})

      params["typing"] == true ->
        timeout_ms = params["timeout"] || 30_000
        Typing.start(room_id, user_id, timeout_ms)
        EventStore.record_ephemeral_update(room_id)
        federate_typing(room_id, user_id, true, timeout_ms)
        json(conn, %{})

      true ->
        Typing.stop(room_id, user_id)
        EventStore.record_ephemeral_update(room_id)
        federate_typing(room_id, user_id, false, 0)
        json(conn, %{})
    end
  end

  defp joined?(room_id, user_id) do
    case EventStore.get_membership(room_id, user_id) do
      {:ok, "join"} -> true
      _ -> false
    end
  end

  defp federate_typing(room_id, user_id, typing, timeout_ms) do
    case EventStore.remote_servers_for_room(room_id) do
      [] ->
        :ok

      remote_servers ->
        edu = %{
          "edu_type" => "m.typing",
          "content" => %{
            "room_id" => room_id,
            "user_id" => user_id,
            "typing" => typing,
            "timeout" => timeout_ms
          }
        }

        Enum.each(remote_servers, fn server ->
          Phoenix.PubSub.broadcast(Axon.PubSub, "federation:fanout", {:federate_edu, edu, server})
        end)
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/forget
  def forget(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.current_user_id

    row =
      Repo.one(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.user_id == ^user_id,
          select: %{membership: m.membership}
        )
      )

    cond do
      row != nil and row.membership in ["join", "invite"] ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_UNKNOWN", "error" => "You must leave the room first"})

      row == nil ->
        json(conn, %{})

      true ->
        # Mark as forgotten (don't delete — we need the leave event in incremental sync)
        Repo.update_all(
          from(m in "room_memberships",
            where: m.room_id == ^room_id and m.user_id == ^user_id
          ),
          set: [forgotten: true]
        )

        json(conn, %{})
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/upgrade
  def upgrade(conn, %{"room_id" => room_id, "new_version" => new_version} = params)
      when is_binary(new_version) do
    user_id = conn.assigns.current_user_id
    server_name = Application.fetch_env!(:axon_web, :server_name)
    upgrade_opts = [additional_creators: params["additional_creators"]]

    with :ok <- RoomUpgrade.ensure_joined(room_id, user_id),
         :ok <- RoomUpgrade.ensure_can_tombstone(room_id, user_id),
         {:ok, new_room_id} <-
           RoomUpgrade.execute(room_id, user_id, new_version, server_name, upgrade_opts) do
      json(conn, %{"replacement_room" => new_room_id})
    else
      {:error, :not_joined} ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not joined to this room"})

      {:error, :insufficient_power_level} ->
        conn
        |> put_status(403)
        |> json(%{
          "errcode" => "M_FORBIDDEN",
          "error" => "Insufficient power level to upgrade room"
        })

      {:error, :unsupported_room_version} ->
        conn
        |> put_status(400)
        |> json(%{
          "errcode" => "M_UNSUPPORTED_ROOM_VERSION",
          "error" => "Unsupported room version"
        })

      # Same atom CreateRoom uses for a malformed additional_creators —
      # fallback_controller.ex already maps it to 400 M_INVALID_PARAM.
      {:error, :invalid_additional_creators} = err ->
        err
    end
  end

  def upgrade(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_BAD_JSON", "error" => "new_version is required"})
  end

  # POST /_matrix/client/v3/rooms/:room_id/invite
  def invite(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id

    cond do
      params["user_id"] ->
        with {:ok, _event_id} <- invite_user(room_id, user_id, params["user_id"]) do
          json(conn, %{})
        end

      params["medium"] && params["address"] ->
        invite_3pid(conn, room_id, user_id, params)

      true ->
        conn
        |> put_status(400)
        |> json(%{
          "errcode" => "M_MISSING_PARAM",
          "error" => "user_id, or medium+address, required"
        })
    end
  end

  # A same-server invite goes through RoomProcess.send_event/5 as before —
  # auth-checked, built, persisted, and broadcast the normal local way. A
  # cross-server invite previously did the exact same thing regardless of
  # the target's server, which meant the resulting m.room.member "invite"
  # event only ever existed in *our* DB — nothing ever told the invitee's
  # own homeserver about it over federation (there was no outbound
  # `PUT .../federation/v2/invite/...` call anywhere in the codebase, and
  # no inbound route to receive one either), so a federated invite was
  # silently a no-op from the invitee's perspective.
  defp invite_user(room_id, sender, target_user_id) do
    local_server = AxonCrypto.KeyServer.server_name()
    target_server = target_user_id |> AxonCore.MatrixId.server_name()

    if target_server == local_server do
      RoomProcess.send_event(room_id, sender, "m.room.member", %{"membership" => "invite"},
        state_key: target_user_id
      )
    else
      federate_invite(room_id, sender, target_user_id, target_server)
    end
  end

  # Builds and self-signs the invite event exactly like a local send would
  # (same AxonRoom.EventBuilder, same auth check — a would-be inviter
  # without invite power is rejected here, before anything is sent out,
  # not just for the same-server case), then round-trips it through the
  # target server's federation `/invite` endpoint per spec: they add their
  # own signature and hand back the final event, which is what actually
  # gets persisted — via RoomProcess.apply_remote_event/2, the same path
  # any other remote-originated event takes, so local /sync fan-out works
  # identically to a same-server invite.
  defp federate_invite(room_id, sender, target_user_id, target_server) do
    room_ctx = RoomProcess.get_room_ctx(room_id)

    invite_event =
      EventBuilder.build(sender, "m.room.member", %{"membership" => "invite"}, room_ctx,
        state_key: target_user_id
      )

    with :ok <- AuthRules.check(invite_event, room_ctx.current_state, room_ctx.room_version) do
      body = %{
        "room_version" => room_ctx.room_version,
        "event" => invite_event,
        "invite_room_state" => AxonWeb.SyncHelpers.preview_state_events(room_id)
      }

      path =
        "/_matrix/federation/v2/invite/#{URI.encode(room_id)}/#{URI.encode(invite_event["event_id"])}"

      case AxonFederation.HttpClient.put(target_server, path, body) do
        {:ok, %{"event" => signed_event}} when is_map(signed_event) ->
          # Room versions 3+ carry no event_id on the wire — it's the event's
          # own reference hash — so the countersigned event we get back has no
          # event_id field even though the one we sent did. Inserting it as-is
          # failed the events table's NOT NULL event_id and surfaced as an
          # opaque 500 on the *inviter's* /invite call. Adding the remote's
          # signature doesn't change the reference hash (signatures are
          # excluded from it), so recomputing yields the same id we sent.
          signed_event =
            Map.put_new_lazy(signed_event, "event_id", fn ->
              AxonCrypto.EventHash.reference_hash(signed_event, room_ctx.room_version)
            end)

          RoomProcess.apply_remote_event(room_id, signed_event)

        {:ok, _malformed} ->
          {:error, :remote_invite_failed}

        {:error, _reason} ->
          {:error, :remote_invite_failed}
      end
    end
  end

  # Third-party (3pid) invite: no Matrix user ID is known yet, so unlike a
  # normal invite this creates an m.room.third_party_invite state event
  # (AuthRules rule 7) rather than an m.room.member one — the eventual
  # invitee only gets a real membership row once they present the signed
  # proof this generates back through /join (see AuthRules.valid_third_party_invite?/3
  # and AxonRoom.EventBuilder for the join-side wiring).
  #
  # Known gap: axon has no identity-server integration, so nothing actually
  # delivers this invite to the 3pid address (no email/SMS is sent) — the
  # room-state mechanics and cryptographic proof are fully real and
  # spec-shaped (self-signed with this server's own key, since there's no
  # external identity server to delegate to), but getting the token to the
  # invitee is left to an out-of-band channel until a real mail/identity
  # integration exists.
  defp invite_3pid(conn, room_id, user_id, params) do
    medium = params["medium"]
    address = params["address"]
    token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    server_name = AxonCrypto.KeyServer.server_name()
    %{public_key_b64: public_key_b64} = AxonCrypto.KeyServer.server_key_info()
    key_validity_url = "https://#{server_name}/_matrix/identity/v2/pubkey/isvalid"

    content = %{
      "display_name" => obfuscate_3pid(medium, address),
      "key_validity_url" => key_validity_url,
      "public_key" => public_key_b64,
      "public_keys" => [%{"public_key" => public_key_b64, "key_validity_url" => key_validity_url}]
    }

    with {:ok, _event_id} <-
           RoomProcess.send_event(room_id, user_id, "m.room.third_party_invite", content,
             state_key: token
           ) do
      json(conn, %{})
    end
  end

  defp obfuscate_3pid(_medium, address) do
    case String.split(address, "@", parts: 2) do
      [local, domain] when byte_size(local) > 3 ->
        String.slice(local, 0, 3) <>
          String.duplicate("*", max(byte_size(local) - 3, 3)) <> "@" <> domain

      [local, domain] ->
        String.duplicate("*", byte_size(local)) <> "@" <> domain

      _ ->
        String.duplicate("*", String.length(address))
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/kick
  def kick(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id
    target = params["user_id"]
    reason = params["reason"]

    content = %{"membership" => "leave"}
    content = if reason, do: Map.put(content, "reason", reason), else: content

    with {:ok, _event_id} <-
           RoomProcess.send_event(room_id, user_id, "m.room.member", content, state_key: target) do
      json(conn, %{})
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/ban
  def ban(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id
    target = params["user_id"]
    reason = params["reason"]

    content = %{"membership" => "ban"}
    content = if reason, do: Map.put(content, "reason", reason), else: content

    with {:ok, _event_id} <-
           RoomProcess.send_event(room_id, user_id, "m.room.member", content, state_key: target) do
      json(conn, %{})
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/unban
  def unban(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id
    target = params["user_id"]

    with {:ok, _event_id} <-
           RoomProcess.send_event(room_id, user_id, "m.room.member", %{"membership" => "leave"},
             state_key: target
           ) do
      json(conn, %{})
    end
  end

  # GET /_matrix/client/v3/rooms/:room_id/members
  def members(conn, %{"room_id" => room_id} = params) do
    filter_memberships =
      case params["membership"] do
        nil -> ["join", "invite", "ban", "leave", "knock"]
        m -> [m]
      end

    filter_memberships =
      case params["not_membership"] do
        nil -> filter_memberships
        m -> List.delete(filter_memberships, m)
      end

    members = EventStore.get_room_members(room_id, filter_memberships)

    chunk =
      Enum.map(members, fn m ->
        %{
          "content" => %{"membership" => m.membership},
          "membership" => m.membership,
          "room_id" => m.room_id,
          "sender" => m.sender,
          "state_key" => m.user_id,
          "type" => "m.room.member"
        }
      end)

    json(conn, %{"chunk" => chunk})
  end

  # GET /_matrix/client/v3/rooms/:room_id/joined_members
  def joined_members(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.current_user_id

    membership =
      Repo.one(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.user_id == ^user_id,
          select: m.membership
        )
      )

    if membership != "join" do
      conn
      |> put_status(403)
      |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})
    else
      members = EventStore.get_room_members(room_id, ["join"])

      joined =
        Enum.into(members, %{}, fn m ->
          {m.user_id, %{"display_name" => m.display_name, "avatar_url" => m.avatar_url}}
        end)

      json(conn, %{"joined" => joined})
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Builds the m.room.member "join" content for a local join, stamping
  # join_authorised_via_users_server when the room is restricted and the
  # user isn't already invited (MSC3083). Returns {:error, :restricted_join_denied}
  # if the room is restricted and the user isn't allow-listed either.
  #
  # Per spec, the client's request body is used as the join event's content
  # (e.g. a client-chosen "foo": "bar" survives onto the stored event) —
  # `params` is the raw request params (path param plus JSON body merged by
  # Phoenix), so server-controlled keys are dropped from it first and any
  # server-computed fields are merged on *top* of what's left, so a client
  # can't forge its own "membership" or "join_authorised_via_users_server".
  defp build_join_content(room_id, user_id, params) do
    client_content = Map.drop(params, ~w(room_id third_party_signed server_name))
    third_party_signed = params["third_party_signed"]

    current_state = EventStore.get_current_state_map(room_id)
    join_rule_event = current_state[{"m.room.join_rules", ""}]
    join_rule = get_in(join_rule_event, ["content", "join_rule"]) || "invite"

    sender_membership =
      get_in(current_state[{"m.room.member", user_id}], ["content", "membership"])

    with :ok <- check_room_not_blocked(room_id),
         :ok <- check_guest_access(user_id, current_state, sender_membership) do
      result =
        cond do
          join_rule not in ["restricted", "knock_restricted"] ->
            {:ok, Map.merge(client_content, %{"membership" => "join"})}

          sender_membership in ["invite", "join"] ->
            {:ok, Map.merge(client_content, %{"membership" => "join"})}

          true ->
            join_rule_content = (join_rule_event && join_rule_event["content"]) || %{}

            case RestrictedJoin.authorise(join_rule_content, user_id, current_state) do
              {:ok, authoriser} ->
                {:ok,
                 Map.merge(client_content, %{
                   "membership" => "join",
                   "join_authorised_via_users_server" => authoriser
                 })}

              {:error, _} = err ->
                err
            end
        end

      with {:ok, content} <- result do
        {:ok, maybe_attach_third_party_invite(content, third_party_signed)}
      end
    end
  end

  # A client that obtained proof of 3pid ownership (mxid/token/signatures —
  # see AuthRules.valid_third_party_invite?/3 for how it's verified)
  # attaches it here; harmless to attach speculatively when absent/invalid —
  # AuthRules just won't treat it as an authorization escape hatch, and the
  # join falls through to the room's normal join_rule check instead.
  defp maybe_attach_third_party_invite(content, %{"mxid" => _, "token" => _} = signed) do
    Map.put(content, "third_party_invite", %{"signed" => signed})
  end

  defp maybe_attach_third_party_invite(content, _), do: content

  defp check_room_not_blocked(room_id) do
    if EventStore.room_blocked?(room_id), do: {:error, :room_blocked}, else: :ok
  end

  # Guests may only join without an existing invite when the room opts in
  # via m.room.guest_access: can_join (default is "forbidden"). An invited
  # guest can still accept, same as any other user.
  defp check_guest_access(user_id, current_state, sender_membership) do
    if sender_membership == "invite" or not AxonCore.UserStore.guest?(user_id) do
      :ok
    else
      guest_access =
        get_in(current_state[{"m.room.guest_access", ""}], ["content", "guest_access"]) ||
          "forbidden"

      if guest_access == "can_join", do: :ok, else: {:error, :guest_access_forbidden}
    end
  end

  # `server_name` hints can legally arrive from a caller as a list (already
  # normalized), a bare string (a single `?server_name=x` — see
  # server_name_hints/1), or nil/absent — List.wrap handles all three. Every
  # branch below assumes a list from here on; this used to be the caller's
  # job and wasn't done consistently (the "#" branch crashed — Enum over a
  # raw string — on the single-hint case, the single most common one).
  #
  # Returns {room_id, hint_servers} or {nil, []}
  defp resolve_room(room_id_or_alias, local_server, server_params) do
    server_params = List.wrap(server_params)

    cond do
      String.starts_with?(room_id_or_alias, "#") ->
        # Alias — try local first
        local_id =
          Repo.one(
            from(a in "room_aliases", where: a.alias == ^room_id_or_alias, select: a.room_id)
          )

        if local_id do
          {local_id, []}
        else
          # Try federation alias lookup
          alias_server = room_id_or_alias |> AxonCore.MatrixId.server_name()
          # List.wrap so a malformed alias with no server part yields no via
          # hint at all, rather than a [nil] we'd then try to connect to.
          via = if server_params != [], do: server_params, else: List.wrap(alias_server)
          resolve_remote_alias(room_id_or_alias, via, local_server)
        end

      String.starts_with?(room_id_or_alias, "!") ->
        {room_id_or_alias, server_params}

      true ->
        {nil, []}
    end
  end

  # The `server_name` query param (join/knock via-hints) can legally repeat
  # (`?server_name=a&server_name=b`) — Plug's default query parser collapses
  # repeated bare (non-bracketed) keys to just the last occurrence, so
  # `params["server_name"]` alone would silently drop every hint but one.
  # Reading the raw query string directly preserves all of them.
  defp server_name_hints(conn) do
    conn.query_string
    |> URI.query_decoder()
    |> Enum.filter(fn {k, _v} -> k == "server_name" end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  defp resolve_remote_alias(room_alias, via_servers, _local_server) do
    Enum.find_value(via_servers, {nil, []}, fn server ->
      case AxonFederation.HttpClient.get(
             server,
             "/_matrix/federation/v1/query/directory?room_alias=#{URI.encode(room_alias)}"
           ) do
        {:ok, %{"room_id" => room_id, "servers" => servers}} ->
          {room_id, servers}

        _ ->
          false
      end
    end)
  end
end
