defmodule AxonWeb.FederationController do
  @moduledoc """
  Inbound Server-Server API handlers.

  All routes are authenticated via X-Matrix header (AxonWeb.Plug.FederationAuth).
  """

  use Phoenix.Controller, formats: [:json]

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, KeyStore, Repo}
  alias AxonCore.Schema.Event
  alias AxonCrypto.{EventHash, KeyServer}
  alias AxonRoom.{RestrictedJoin, RoomProcess}
  alias AxonFederation.KeyCache
  require Logger

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/make_join/:room_id/:user_id
  # ---------------------------------------------------------------------------

  def make_join(conn, %{"room_id" => room_id, "user_id" => user_id} = params) do
    supported_versions = (params["ver"] || ["1", "11"]) |> List.wrap()

    # Verify the origin server is allowed to make this request
    # (user_id's server must match origin)
    origin = conn.assigns[:origin_server]
    user_server = user_id |> String.split(":") |> List.last()

    cond do
      user_server != origin ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "User ID domain does not match origin"})

      not room_exists?(room_id) ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found"})

      true ->
        room_ctx = RoomProcess.get_room_ctx(room_id)

        case join_member_content(room_ctx.current_state, user_id) do
          {:error, _reason} ->
            conn
            |> put_status(403)
            |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Join not allowed"})

          {:ok, member_content} ->
            version = pick_room_version(room_id, supported_versions)

            # Build partial join event (no hashes/signatures — remote fills those in)
            template = build_join_template(room_id, user_id, member_content)

            json(conn, %{
              "room_version" => version,
              "event" => template
            })
        end
    end
  end

  # Mirrors AuthRules' join_rule cond, minus the room_creator? escape hatch
  # (a remote-server make_join is never the room's original creator). For
  # restricted/knock_restricted rules, delegates the allow-list check to
  # AxonRoom.RestrictedJoin and stamps join_authorised_via_users_server on
  # success — AuthRules verifies that stamp when the signed join comes back
  # in via send_join.
  defp join_member_content(current_state, user_id) do
    join_rule_event = current_state[{"m.room.join_rules", ""}]
    join_rule = get_in(join_rule_event, ["content", "join_rule"]) || "invite"

    sender_membership =
      get_in(current_state[{"m.room.member", user_id}], ["content", "membership"])

    cond do
      sender_membership == "ban" ->
        {:error, :banned}

      sender_membership in ["invite", "join"] ->
        {:ok, %{"membership" => "join"}}

      join_rule in ["public", "open"] ->
        {:ok, %{"membership" => "join"}}

      join_rule in ["restricted", "knock_restricted"] ->
        join_rule_content = (join_rule_event && join_rule_event["content"]) || %{}

        case RestrictedJoin.authorise(join_rule_content, user_id, current_state) do
          {:ok, authoriser} ->
            {:ok, %{"membership" => "join", "join_authorised_via_users_server" => authoriser}}

          {:error, _} = err ->
            err
        end

      true ->
        {:error, :not_invited}
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /_matrix/federation/v2/send_join/:room_id/:event_id
  # ---------------------------------------------------------------------------

  def send_join(conn, %{"room_id" => room_id, "event_id" => _event_id} = params) do
    # The request body IS the join event (room_id/event_id are legitimate
    # event fields, not just routing params to be stripped — dropping them
    # here used to make validate_join_event's room_id check always fail and
    # left the event with no event_id to persist under).
    join_event = params

    with :ok <- validate_join_event(join_event, room_id),
         :ok <- verify_event_signature(join_event),
         {:ok, event_id} <- apply_join_event(room_id, join_event) do
      # Build response: full room state + auth chain
      state_events = EventStore.get_current_state(room_id)
      state_maps = Enum.map(state_events, &EventStore.event_to_map/1)

      auth_chain = build_auth_chain_for_state(state_events)

      json(conn, %{
        "origin" => KeyServer.server_name(),
        "auth_chain" => auth_chain,
        "state" => state_maps,
        "event" => EventStore.event_to_map_by_id(event_id)
      })
    else
      {:error, :invalid_join} ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_BAD_JSON", "error" => "Invalid join event"})

      {:error, sig_error} when sig_error in [:bad_signature, :missing_signature, :key_not_found] ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Bad event signature"})

      {:error, :auth_failed} ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Event failed auth check"})

      _ ->
        conn |> put_status(500) |> json(%{"errcode" => "M_UNKNOWN", "error" => "Internal error"})
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/make_leave/:room_id/:user_id
  # ---------------------------------------------------------------------------

  def make_leave(conn, %{"room_id" => room_id, "user_id" => user_id}) do
    origin = conn.assigns[:origin_server]
    user_server = user_id |> String.split(":") |> List.last()

    cond do
      user_server != origin ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "User ID domain does not match origin"})

      not room_exists?(room_id) ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found"})

      true ->
        version = get_room_version(room_id)
        template = build_leave_template(room_id, user_id)

        json(conn, %{
          "room_version" => version,
          "event" => template
        })
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /_matrix/federation/v2/send_leave/:room_id/:event_id
  # ---------------------------------------------------------------------------

  def send_leave(conn, %{"room_id" => room_id} = params) do
    # See send_join/2 — the body IS the leave event; don't strip its fields.
    leave_event = params

    with :ok <- verify_event_signature(leave_event),
         {:ok, _} <- apply_leave_event(room_id, leave_event) do
      json(conn, %{})
    else
      {:error, sig_error} when sig_error in [:bad_signature, :missing_signature, :key_not_found] ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Bad event signature"})

      _ ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_BAD_JSON", "error" => "Invalid leave event"})
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/make_knock/:room_id/:user_id
  # ---------------------------------------------------------------------------

  def make_knock(conn, %{"room_id" => room_id, "user_id" => user_id} = params) do
    supported_versions = (params["ver"] || ["7", "8", "9", "10", "11"]) |> List.wrap()
    origin = conn.assigns[:origin_server]
    user_server = user_id |> String.split(":") |> List.last()

    cond do
      user_server != origin ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "User ID domain does not match origin"})

      not room_exists?(room_id) ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found"})

      true ->
        room_ctx = RoomProcess.get_room_ctx(room_id)

        join_rule =
          get_in(room_ctx.current_state[{"m.room.join_rules", ""}], ["content", "join_rule"])

        if join_rule not in ["knock", "knock_restricted"] do
          conn
          |> put_status(403)
          |> json(%{"errcode" => "M_FORBIDDEN", "error" => "This room does not support knocking"})
        else
          version = pick_room_version(room_id, supported_versions)
          template = build_knock_template(room_id, user_id)
          json(conn, %{"room_version" => version, "event" => template})
        end
    end
  end

  defp build_knock_template(room_id, user_id) do
    room_ctx = RoomProcess.get_room_ctx(room_id)

    %{
      "type" => "m.room.member",
      "room_id" => room_id,
      "sender" => user_id,
      "state_key" => user_id,
      "content" => %{"membership" => "knock"},
      "origin_server_ts" => System.os_time(:millisecond),
      "origin" => user_id |> String.split(":") |> List.last(),
      "prev_events" => if(room_ctx.last_event_id, do: [room_ctx.last_event_id], else: []),
      "auth_events" => select_join_auth_events(user_id, room_ctx.current_state),
      "depth" => room_ctx.depth + 1
    }
  end

  # ---------------------------------------------------------------------------
  # PUT /_matrix/federation/v1/send_knock/:room_id/:event_id
  # ---------------------------------------------------------------------------

  def send_knock(conn, %{"room_id" => room_id} = params) do
    # See send_join/2 — the body IS the knock event; don't strip its fields.
    knock_event = params

    with :ok <- validate_knock_event(knock_event, room_id),
         :ok <- verify_event_signature(knock_event),
         {:ok, _event_id} <- apply_knock_event(room_id, knock_event) do
      json(conn, %{"knock_room_state" => EventStore.stripped_state_events(room_id)})
    else
      {:error, :invalid_knock} ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_BAD_JSON", "error" => "Invalid knock event"})

      {:error, sig_error} when sig_error in [:bad_signature, :missing_signature, :key_not_found] ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Bad event signature"})

      {:error, :auth_failed} ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Event failed auth check"})

      _ ->
        conn |> put_status(500) |> json(%{"errcode" => "M_UNKNOWN", "error" => "Internal error"})
    end
  end

  defp validate_knock_event(event, room_id) do
    cond do
      event["type"] != "m.room.member" -> {:error, :invalid_knock}
      event["room_id"] != room_id -> {:error, :invalid_knock}
      get_in(event, ["content", "membership"]) != "knock" -> {:error, :invalid_knock}
      true -> :ok
    end
  end

  # Goes through RoomProcess.apply_remote_event/2 (not a direct
  # EventStore.insert_event) so the room's live GenServer state, local
  # /sync fan-out, and federation fan-out all learn about the knock
  # immediately — a direct DB write would leave them stale until the next
  # restart, silently breaking auth checks for that user's subsequent
  # events and federation fan-out to them.
  defp apply_knock_event(room_id, knock_event) do
    case RoomProcess.apply_remote_event(room_id, knock_event) do
      {:ok, event_id} -> {:ok, event_id}
      {:error, _reason} -> {:error, :auth_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /_matrix/federation/v1/send/:txn_id
  # Receive PDUs from remote server
  # ---------------------------------------------------------------------------

  def send_transaction(conn, %{"txn_id" => txn_id} = params) do
    origin = conn.assigns[:origin_server]
    pdus = params["pdus"] || []
    edus = params["edus"] || []

    # Check idempotency
    already_processed =
      Repo.one(
        from(t in "federation_inbound_txns",
          where: t.origin == ^origin and t.txn_id == ^txn_id and t.processed == true,
          select: t.id
        )
      )

    if already_processed do
      json(conn, %{"pdus" => %{}})
    else
      # Process each PDU
      pdu_results =
        Enum.into(pdus, %{}, fn pdu ->
          event_id = pdu["event_id"] || compute_event_id(pdu)
          result = process_inbound_pdu(pdu, origin)

          {event_id,
           case result do
             :ok -> %{}
             {:error, reason} -> %{"error" => inspect(reason)}
           end}
        end)

      Enum.each(edus, &process_inbound_edu(&1, origin))

      # Record transaction
      Repo.insert_all(
        "federation_inbound_txns",
        [
          %{
            origin: origin,
            txn_id: txn_id,
            processed: true,
            inserted_at: DateTime.utc_now(:microsecond)
          }
        ],
        on_conflict: :nothing
      )

      json(conn, %{"pdus" => pdu_results})
    end
  end

  # Only m.direct_to_device is handled today (the E2EE relay path this fixes);
  # other EDU types (m.typing, m.receipt, m.presence) are a later phase.
  defp process_inbound_edu(%{"edu_type" => "m.direct_to_device", "content" => content}, origin) do
    sender = content["sender"]
    event_type = content["type"]
    messages = content["messages"] || %{}
    local_server = KeyServer.server_name()

    sender_server = sender |> to_string() |> String.split(":") |> List.last()

    if sender_server == origin do
      Enum.each(messages, fn {target_user_id, device_messages} ->
        if local_user?(target_user_id, local_server) do
          KeyStore.deliver_to_device(sender, target_user_id, event_type, device_messages)
        end
      end)
    else
      Logger.warning(
        "Dropping m.direct_to_device EDU from #{origin} claiming sender #{sender}"
      )
    end
  end

  defp process_inbound_edu(_edu, _origin), do: :ok

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/event/:event_id
  # ---------------------------------------------------------------------------

  def get_event(conn, %{"event_id" => event_id}) do
    case EventStore.get_event(event_id) do
      {:ok, event} ->
        json(conn, %{
          "origin" => KeyServer.server_name(),
          "origin_server_ts" => event.origin_server_ts,
          "pdus" => [EventStore.event_to_map(event)]
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Event not found"})
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/state/:room_id
  # ---------------------------------------------------------------------------

  def get_state(conn, %{"room_id" => room_id}) do
    state_events = EventStore.get_current_state(room_id)
    auth_chain = build_auth_chain_for_state(state_events)

    json(conn, %{
      "pdus" => Enum.map(state_events, &EventStore.event_to_map/1),
      "auth_chain" => auth_chain
    })
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/state_ids/:room_id
  # ---------------------------------------------------------------------------

  def get_state_ids(conn, %{"room_id" => room_id} = params) do
    _event_id = params["event_id"]

    state_events = EventStore.get_current_state(room_id)
    state_ids = Enum.map(state_events, & &1.event_id)

    auth_chain_ids =
      state_events
      |> Enum.flat_map(&get_auth_chain_ids(&1))
      |> Enum.uniq()

    json(conn, %{
      "pdu_ids" => state_ids,
      "auth_chain_ids" => auth_chain_ids
    })
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/backfill/:room_id
  # ---------------------------------------------------------------------------

  def backfill(conn, %{"room_id" => room_id} = params) do
    v_param = params["v"] || []
    limit = String.to_integer(params["limit"] || "100")

    # Find the ordering of the v events, then return events before them
    from_ordering =
      case v_param do
        [] ->
          EventStore.room_max_stream_ordering(room_id)

        ids ->
          Repo.one(
            from(e in Event,
              where: e.event_id in ^ids and e.room_id == ^room_id,
              select: min(e.stream_ordering)
            )
          ) || 0
      end

    events =
      Repo.all(
        from(e in Event,
          where: e.room_id == ^room_id and e.stream_ordering < ^from_ordering,
          order_by: [desc: e.stream_ordering],
          limit: ^limit
        )
      )

    json(conn, %{
      "origin" => KeyServer.server_name(),
      "origin_server_ts" => System.os_time(:millisecond),
      "pdus" => Enum.map(events, &EventStore.event_to_map/1)
    })
  end

  # ---------------------------------------------------------------------------
  # POST /_matrix/federation/v1/get_missing_events/:room_id
  # ---------------------------------------------------------------------------

  def get_missing_events(conn, %{"room_id" => room_id} = params) do
    known_ids = MapSet.new(params["known_ids"] || [])
    limit = params["limit"] || 10

    events =
      Repo.all(
        from(e in Event,
          where: e.room_id == ^room_id and e.event_id not in ^MapSet.to_list(known_ids),
          order_by: [desc: e.stream_ordering],
          limit: ^limit
        )
      )

    json(conn, %{
      "events" => Enum.map(events, &EventStore.event_to_map/1)
    })
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/query/directory?room_alias=...
  # ---------------------------------------------------------------------------

  def query_directory(conn, %{"room_alias" => room_alias}) do
    case Repo.one(from(a in "room_aliases", where: a.alias == ^room_alias, select: a.room_id)) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room alias not found"})

      room_id ->
        json(conn, %{
          "room_id" => room_id,
          "servers" => [KeyServer.server_name()]
        })
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/query/profile?user_id=...
  # ---------------------------------------------------------------------------

  def query_profile(conn, %{"user_id" => user_id}) do
    # Profile data lives on user_profiles (displayname/avatar_url) — the
    # `users` table has neither column.
    case Repo.one(
           from(p in "user_profiles",
             where: p.user_id == ^user_id,
             select: %{displayname: p.displayname, avatar_url: p.avatar_url}
           )
         ) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "User not found"})

      profile ->
        json(conn, %{
          "displayname" => profile.displayname,
          "avatar_url" => profile.avatar_url
        })
    end
  end

  # ---------------------------------------------------------------------------
  # POST /_matrix/federation/v1/user/keys/query
  # Remote servers ask us for the device/cross-signing keys of OUR users.
  # ---------------------------------------------------------------------------

  def query_user_keys(conn, params) do
    device_keys_req = params["device_keys"] || %{}
    local_server = KeyServer.server_name()

    user_ids =
      device_keys_req
      |> Map.keys()
      |> Enum.filter(&local_user?(&1, local_server))

    device_keys_result =
      Enum.into(user_ids, %{}, fn user_id ->
        requested_devices = List.wrap(device_keys_req[user_id])

        devices =
          user_id
          |> KeyStore.device_keys_for_user()
          |> maybe_filter_devices(requested_devices)

        {user_id, devices}
      end)

    sigs_by_target = KeyStore.cross_signing_signatures(user_ids, nil)

    master_keys =
      KeyStore.cross_signing_keys(user_ids, "master")
      |> KeyStore.merge_cross_signing_key_signatures(sigs_by_target)

    self_signing_keys =
      KeyStore.cross_signing_keys(user_ids, "self_signing")
      |> KeyStore.merge_cross_signing_key_signatures(sigs_by_target)

    json(conn, %{
      "device_keys" => device_keys_result,
      "master_keys" => master_keys,
      "self_signing_keys" => self_signing_keys
    })
  end

  defp maybe_filter_devices(devices, []), do: devices

  defp maybe_filter_devices(devices, wanted_ids),
    do: Map.take(devices, wanted_ids)

  # ---------------------------------------------------------------------------
  # POST /_matrix/federation/v1/user/keys/claim
  # Remote servers claim one-time-keys from OUR users' devices.
  # ---------------------------------------------------------------------------

  def claim_user_keys(conn, params) do
    one_time_keys_request = params["one_time_keys"] || %{}
    local_server = KeyServer.server_name()

    result =
      Enum.into(one_time_keys_request, %{}, fn {user_id, device_map} ->
        device_result =
          if local_user?(user_id, local_server) do
            Enum.into(device_map, %{}, fn {device_id, algorithm} ->
              key = KeyStore.claim_one_time_key(user_id, device_id, algorithm)
              {device_id, key || %{}}
            end)
          else
            %{}
          end

        {user_id, device_result}
      end)

    json(conn, %{"one_time_keys" => result})
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/user/devices/:user_id
  # ---------------------------------------------------------------------------

  def get_user_devices(conn, %{"user_id" => user_id}) do
    local_server = KeyServer.server_name()

    if not local_user?(user_id, local_server) do
      conn
      |> put_status(404)
      |> json(%{"errcode" => "M_NOT_FOUND", "error" => "User not found on this server"})
    else
      device_keys = KeyStore.device_keys_for_user(user_id)
      display_names = KeyStore.device_display_names(user_id)

      devices =
        Enum.map(device_keys, fn {device_id, key_json} ->
          %{
            "device_id" => device_id,
            "keys" => key_json,
            "device_display_name" => Map.get(display_names, device_id)
          }
        end)

      master_key = KeyStore.cross_signing_keys([user_id], "master")[user_id]
      self_signing_key = KeyStore.cross_signing_keys([user_id], "self_signing")[user_id]

      json(conn, %{
        "user_id" => user_id,
        "stream_id" => KeyStore.device_list_stream_id(user_id),
        "devices" => devices,
        "master_key" => master_key,
        "self_signing_key" => self_signing_key
      })
    end
  end

  defp local_user?(user_id, local_server) do
    user_id |> String.split(":") |> List.last() == local_server
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/key/v2/query (batch key query from remote servers)
  # ---------------------------------------------------------------------------

  def query_keys(conn, _params) do
    info = KeyServer.server_key_info()

    json(conn, %{
      "server_keys" => [
        %{
          "server_name" => info.server_name,
          "verify_keys" => %{info.key_id => %{"key" => info.public_key_b64}},
          "old_verify_keys" => %{},
          "signatures" => info.signatures,
          "valid_until_ts" => info.valid_until_ts
        }
      ]
    })
  end

  # ---------------------------------------------------------------------------
  # Helpers — event validation & application
  # ---------------------------------------------------------------------------

  defp validate_join_event(event, room_id) do
    cond do
      event["type"] != "m.room.member" -> {:error, :invalid_join}
      event["room_id"] != room_id -> {:error, :invalid_join}
      get_in(event, ["content", "membership"]) != "join" -> {:error, :invalid_join}
      true -> :ok
    end
  end

  defp verify_event_signature(event) do
    sender_server = event["sender"] |> String.split(":") |> List.last()
    origin = event["origin"] || sender_server

    # Try to find a key_id from the event's signatures
    key_id = get_in(event, ["signatures", origin]) |> maybe_first_key()

    if is_nil(key_id) do
      {:error, :missing_signature}
    else
      pub_key = KeyCache.get_key(origin, key_id)

      if is_nil(pub_key) do
        {:error, :key_not_found}
      else
        AxonCrypto.EventHash.verify_signature(event, origin, key_id, pub_key)
        |> case do
          :ok -> :ok
          {:error, _} -> {:error, :bad_signature}
        end
      end
    end
  end

  defp maybe_first_key(nil), do: nil

  defp maybe_first_key(map) when is_map(map) do
    case Map.keys(map) do
      [] -> nil
      [key | _] -> key
    end
  end

  # See apply_knock_event/2 — must go through RoomProcess.apply_remote_event/2,
  # not a direct EventStore.insert_event, or the room's live GenServer never
  # learns the remote user joined (federation fan-out silently excludes them,
  # /sync doesn't show the join in real time, and their next event over
  # send_transaction gets wrongly auth-rejected as "not_joined" until the
  # room process happens to restart).
  defp apply_join_event(room_id, join_event) do
    case RoomProcess.apply_remote_event(room_id, join_event) do
      {:ok, event_id} -> {:ok, event_id}
      {:error, _reason} -> {:error, :auth_failed}
    end
  end

  defp apply_leave_event(room_id, leave_event) do
    case RoomProcess.apply_remote_event(room_id, leave_event) do
      {:ok, event_id} -> {:ok, event_id}
      {:error, _reason} -> {:error, :auth_failed}
    end
  end

  defp process_inbound_pdu(pdu, origin) do
    room_id = pdu["room_id"]

    # Basic checks
    unless room_exists?(room_id) do
      # Soft-fail: we don't know this room
      {:error, :unknown_room}
    end

    case verify_event_signature(pdu) do
      :ok ->
        apply_remote_event(pdu, room_id)

      {:error, reason} ->
        Logger.warning("Inbound PDU signature failed from #{origin}: #{inspect(reason)}")
        {:error, :bad_signature}
    end
  end

  defp apply_remote_event(pdu, room_id) do
    case RoomProcess.apply_remote_event(room_id, pdu) do
      {:ok, _event_id} ->
        :ok

      {:error, reason} ->
        Logger.debug("Soft-fail PDU #{pdu["event_id"]}: #{inspect(reason)}")
        # Soft-fail: don't apply to room state, but don't error the transaction either.
        :ok
    end
  end

  defp compute_event_id(pdu) do
    EventHash.reference_hash(pdu)
  end

  # ---------------------------------------------------------------------------
  # Helpers — room state
  # ---------------------------------------------------------------------------

  defp room_exists?(room_id) do
    Repo.one(from(r in "rooms", where: r.room_id == ^room_id, select: r.room_id)) != nil
  end

  defp get_room_version(room_id) do
    Repo.one(from(r in "rooms", where: r.room_id == ^room_id, select: r.version)) || "11"
  end

  defp pick_room_version(room_id, supported_versions) do
    version = get_room_version(room_id)
    if version in supported_versions, do: version, else: "11"
  end

  defp build_join_template(room_id, user_id, member_content) do
    room_ctx = RoomProcess.get_room_ctx(room_id)

    %{
      "type" => "m.room.member",
      "room_id" => room_id,
      "sender" => user_id,
      "state_key" => user_id,
      "content" => member_content,
      "origin_server_ts" => System.os_time(:millisecond),
      "origin" => user_id |> String.split(":") |> List.last(),
      "prev_events" => if(room_ctx.last_event_id, do: [room_ctx.last_event_id], else: []),
      "auth_events" => select_join_auth_events(user_id, room_ctx.current_state),
      "depth" => room_ctx.depth + 1
    }
  end

  defp build_leave_template(room_id, user_id) do
    room_ctx = RoomProcess.get_room_ctx(room_id)

    %{
      "type" => "m.room.member",
      "room_id" => room_id,
      "sender" => user_id,
      "state_key" => user_id,
      "content" => %{"membership" => "leave"},
      "origin_server_ts" => System.os_time(:millisecond),
      "origin" => user_id |> String.split(":") |> List.last(),
      "prev_events" => if(room_ctx.last_event_id, do: [room_ctx.last_event_id], else: []),
      "auth_events" => select_join_auth_events(user_id, room_ctx.current_state),
      "depth" => room_ctx.depth + 1
    }
  end

  defp select_join_auth_events(user_id, current_state) do
    [
      get_in(current_state, [{"m.room.create", ""}, "event_id"]),
      get_in(current_state, [{"m.room.power_levels", ""}, "event_id"]),
      get_in(current_state, [{"m.room.join_rules", ""}, "event_id"]),
      get_in(current_state, [{"m.room.member", user_id}, "event_id"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp build_auth_chain_for_state(state_events) do
    state_events
    |> Enum.flat_map(&get_auth_chain_ids/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn event_id ->
      case EventStore.get_event(event_id) do
        {:ok, e} -> [EventStore.event_to_map(e)]
        _ -> []
      end
    end)
  end

  defp get_auth_chain_ids(event) do
    ids = event.auth_event_ids || []

    (ids ++
       Enum.flat_map(ids, fn id ->
         case EventStore.get_event(id) do
           {:ok, e} -> get_auth_chain_ids(e)
           _ -> []
         end
       end))
    |> Enum.uniq()
  end
end
