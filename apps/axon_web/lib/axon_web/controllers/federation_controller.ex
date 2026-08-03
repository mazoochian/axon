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
  alias AxonRoom.{RestrictedJoin, RoomProcess, ServerAcl}
  alias AxonFederation.{Backfill, EventVerification}
  require Logger

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/make_join/:room_id/:user_id
  # ---------------------------------------------------------------------------

  def make_join(conn, %{"room_id" => room_id, "user_id" => user_id} = params) do
    supported_versions = (params["ver"] || ["1", "11"]) |> List.wrap()

    # Verify the origin server is allowed to make this request
    # (user_id's server must match origin)
    origin = conn.assigns[:origin_server]
    user_server = user_id |> AxonCore.MatrixId.server_name()

    cond do
      user_server != origin ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "User ID domain does not match origin"})

      not room_exists?(room_id) ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found"})

      not acl_allowed?(room_id, origin) ->
        acl_forbidden(conn)

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
    origin = conn.assigns[:origin_server]

    with :ok <- check_acl(room_id, origin),
         :ok <- validate_join_event(join_event, room_id),
         :ok <- verify_event_signature(join_event),
         {:ok, event_id} <- apply_join_event(room_id, join_event, origin) do
      # Build response: full room state + auth chain
      state_events = EventStore.get_current_state(room_id)
      state_maps = Enum.map(state_events, &EventStore.event_to_pdu/1)

      auth_chain = build_auth_chain_for_state(state_events)

      json(conn, %{
        "origin" => KeyServer.server_name(),
        "auth_chain" => auth_chain,
        "state" => state_maps,
        "event" => EventStore.event_to_pdu_by_id(event_id)
      })
    else
      {:error, :acl_denied} ->
        acl_forbidden(conn)

      {:error, :invalid_join} ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_BAD_JSON", "error" => "Invalid join event"})

      {:error, sig_error}
      when sig_error in [:bad_signature, :missing_signature, :key_not_found] ->
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
    user_server = user_id |> AxonCore.MatrixId.server_name()

    cond do
      user_server != origin ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "User ID domain does not match origin"})

      not room_exists?(room_id) ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found"})

      not acl_allowed?(room_id, origin) ->
        acl_forbidden(conn)

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
    origin = conn.assigns[:origin_server]

    with :ok <- check_acl(room_id, origin),
         :ok <- validate_leave_event(leave_event, room_id),
         :ok <- verify_event_signature(leave_event),
         {:ok, _} <- apply_leave_event(room_id, leave_event, origin) do
      json(conn, %{})
    else
      {:error, :acl_denied} ->
        acl_forbidden(conn)

      {:error, :invalid_leave} ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_BAD_JSON", "error" => "Invalid leave event"})

      {:error, sig_error}
      when sig_error in [:bad_signature, :missing_signature, :key_not_found] ->
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
  # PUT /_matrix/federation/v2/invite/:room_id/:event_id
  #
  # A remote resident server inviting one of our local users. Previously
  # unimplemented entirely — no route, no handler — so a federated invite
  # 404'd outright and a local user could never learn one existed. Unlike
  # make_join/send_join, we don't (and structurally can't) already have
  # this room's state: we may be seeing it for the very first time. We
  # don't become resident just from an invite — only the bare membership
  # row plus the sender's `invite_room_state` preview are stored, exactly
  # enough for /sync's invite_state (AxonWeb.SyncHelpers.build_invite_state/2)
  # to show something and for AxonFederation.RoomLeave to reject it later.
  # ---------------------------------------------------------------------------

  def invite(conn, %{"room_id" => room_id} = params) do
    origin = conn.assigns[:origin_server]
    event = params["event"]
    room_version = params["room_version"] || "11"
    invite_room_state = params["invite_room_state"] || []

    with :ok <- check_acl(room_id, origin),
         :ok <- validate_invite_event(event, room_id, origin),
         {:ok, signed_event} <-
           accept_invite(room_id, room_version, event, invite_room_state) do
      json(conn, %{"event" => signed_event})
    else
      {:error, :acl_denied} ->
        acl_forbidden(conn)

      {:error, :invalid_invite} ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_BAD_JSON", "error" => "Invalid invite event"})

      _ ->
        conn |> put_status(500) |> json(%{"errcode" => "M_UNKNOWN", "error" => "Internal error"})
    end
  end

  defp validate_invite_event(event, room_id, origin) when is_map(event) do
    local_server = KeyServer.server_name()
    target_server = event["state_key"] |> to_string() |> AxonCore.MatrixId.server_name()
    sender_server = event["sender"] |> to_string() |> AxonCore.MatrixId.server_name()

    cond do
      event["type"] != "m.room.member" -> {:error, :invalid_invite}
      event["room_id"] != room_id -> {:error, :invalid_invite}
      get_in(event, ["content", "membership"]) != "invite" -> {:error, :invalid_invite}
      target_server != local_server -> {:error, :invalid_invite}
      sender_server != origin -> {:error, :invalid_invite}
      true -> :ok
    end
  end

  defp validate_invite_event(_event, _room_id, _origin), do: {:error, :invalid_invite}

  defp accept_invite(room_id, room_version, event, invite_room_state) do
    signed_event = KeyServer.sign_event(event)
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "rooms",
      [
        %{
          room_id: room_id,
          version: room_version,
          creator: event["sender"],
          is_public: false,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    result =
      case EventStore.insert_event(signed_event, room_version) do
        {:ok, _persisted} -> :ok
        {:error, :already_exists} -> :ok
        {:error, reason} -> {:error, reason}
      end

    with :ok <- result do
      EventStore.set_invite_preview_state(room_id, signed_event["state_key"], invite_room_state)
      {:ok, signed_event}
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/make_knock/:room_id/:user_id
  # ---------------------------------------------------------------------------

  def make_knock(conn, %{"room_id" => room_id, "user_id" => user_id} = params) do
    supported_versions = (params["ver"] || ["7", "8", "9", "10", "11"]) |> List.wrap()
    origin = conn.assigns[:origin_server]
    user_server = user_id |> AxonCore.MatrixId.server_name()

    cond do
      user_server != origin ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "User ID domain does not match origin"})

      not room_exists?(room_id) ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found"})

      not acl_allowed?(room_id, origin) ->
        acl_forbidden(conn)

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
      "origin" => user_id |> AxonCore.MatrixId.server_name(),
      "prev_events" => if(room_ctx.last_event_id, do: [room_ctx.last_event_id], else: []),
      "auth_events" =>
        select_join_auth_events(user_id, room_ctx.current_state, room_ctx.room_version),
      "depth" => room_ctx.depth + 1
    }
  end

  # ---------------------------------------------------------------------------
  # PUT /_matrix/federation/v1/send_knock/:room_id/:event_id
  # ---------------------------------------------------------------------------

  def send_knock(conn, %{"room_id" => room_id} = params) do
    # See send_join/2 — the body IS the knock event; don't strip its fields.
    knock_event = params
    origin = conn.assigns[:origin_server]

    with :ok <- check_acl(room_id, origin),
         :ok <- validate_knock_event(knock_event, room_id),
         :ok <- verify_event_signature(knock_event),
         {:ok, _event_id} <- apply_knock_event(room_id, knock_event, origin) do
      json(conn, %{"knock_room_state" => EventStore.stripped_state_events(room_id)})
    else
      {:error, :acl_denied} ->
        acl_forbidden(conn)

      {:error, :invalid_knock} ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_BAD_JSON", "error" => "Invalid knock event"})

      {:error, sig_error}
      when sig_error in [:bad_signature, :missing_signature, :key_not_found] ->
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
      event["state_key"] != event["sender"] -> {:error, :invalid_knock}
      true -> :ok
    end
  end

  # Goes through RoomProcess.apply_remote_event/3 (not a direct
  # EventStore.insert_event) so the room's live GenServer state, local
  # /sync fan-out, and federation fan-out all learn about the knock
  # immediately — a direct DB write would leave them stale until the next
  # restart, silently breaking auth checks for that user's subsequent
  # events and federation fan-out to them. relay_exclude: origin — this
  # resident server is the only one positioned to relay the new knock on
  # to every OTHER server with a member in the room (the knocking user's
  # own server only knows about us, not them yet); see apply_remote_event/3.
  defp apply_knock_event(room_id, knock_event, origin) do
    case RoomProcess.apply_remote_event(room_id, knock_event, relay_exclude: origin) do
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

  defp process_inbound_edu(%{"edu_type" => "m.typing", "content" => content}, origin) do
    room_id = content["room_id"]
    user_id = content["user_id"]
    typing? = content["typing"] == true
    timeout_ms = content["timeout"] || 30_000

    sender_server = user_id |> to_string() |> AxonCore.MatrixId.server_name()

    if sender_server == origin and local_room_member?(room_id, user_id) and
         acl_allowed?(room_id, origin) do
      if typing?,
        do: AxonSync.Typing.start(room_id, user_id, timeout_ms),
        else: AxonSync.Typing.stop(room_id, user_id)

      EventStore.record_ephemeral_update(room_id)
    else
      Logger.warning(
        "Dropping m.typing EDU from #{origin} for room #{inspect(room_id)}, user #{inspect(user_id)}"
      )
    end
  end

  defp process_inbound_edu(
         %{"edu_type" => "m.presence", "content" => %{"push" => updates}},
         origin
       )
       when is_list(updates) do
    Enum.each(updates, &apply_inbound_presence(&1, origin))
  end

  defp process_inbound_edu(%{"edu_type" => "m.receipt", "content" => content}, origin)
       when is_map(content) do
    Enum.each(content, fn {room_id, receipt_types} ->
      Enum.each(receipt_types, fn {receipt_type, users} ->
        Enum.each(users, fn {user_id, receipt_data} ->
          apply_inbound_receipt(origin, room_id, receipt_type, user_id, receipt_data)
        end)
      end)
    end)
  end

  defp process_inbound_edu(%{"edu_type" => "m.direct_to_device", "content" => content}, origin) do
    sender = content["sender"]
    event_type = content["type"]
    messages = content["messages"] || %{}
    local_server = KeyServer.server_name()

    sender_server = sender |> to_string() |> AxonCore.MatrixId.server_name()

    if sender_server == origin do
      Enum.each(messages, fn {target_user_id, device_messages} ->
        if local_user?(target_user_id, local_server) do
          KeyStore.deliver_to_device(sender, target_user_id, event_type, device_messages)
        end
      end)
    else
      Logger.warning("Dropping m.direct_to_device EDU from #{origin} claiming sender #{sender}")
    end
  end

  # Inbound half of AxonFederation.DeviceListFanout (the outbound sender —
  # see its moduledoc for why gap detection on stream_id/prev_id is
  # deliberately skipped): treated purely as a "go re-query this user's
  # devices" signal, exactly like a local device_lists.changed entry
  # already is. AxonWeb.KeyController's federation /keys/query path
  # (fetch_remote_keys/2) always does a live round trip for a remote
  # user's actual key material rather than trusting a cache, so there's
  # nothing here to reconcile against a missed/reordered update — only
  # local /sync clients who share a room with this user need to be told
  # something changed, the same KeyStore.record_device_list_update/1 every
  # other device-list-changing code path in this codebase already calls.
  defp process_inbound_edu(
         %{"edu_type" => "m.device_list_update", "content" => content},
         origin
       )
       when is_map(content) do
    user_id = content["user_id"]
    sender_server = user_id |> to_string() |> AxonCore.MatrixId.server_name()

    if is_binary(user_id) and sender_server == origin do
      KeyStore.record_device_list_update(user_id)
    else
      Logger.warning(
        "Dropping m.device_list_update EDU from #{origin} claiming user #{inspect(user_id)}"
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
          "pdus" => [EventStore.event_to_pdu(event)]
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
    origin = conn.assigns[:origin_server]

    if acl_allowed?(room_id, origin) do
      state_events = EventStore.get_current_state(room_id)
      auth_chain = build_auth_chain_for_state(state_events)

      json(conn, %{
        "pdus" => Enum.map(state_events, &EventStore.event_to_pdu/1),
        "auth_chain" => auth_chain
      })
    else
      acl_forbidden(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/state_ids/:room_id
  # ---------------------------------------------------------------------------

  def get_state_ids(conn, %{"room_id" => room_id} = params) do
    _event_id = params["event_id"]
    origin = conn.assigns[:origin_server]

    if acl_allowed?(room_id, origin) do
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
    else
      acl_forbidden(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/event_auth/:room_id/:event_id
  #
  # Previously entirely unimplemented (no route at all, so any request
  # here 404'd generically) — one of the endpoints the Server-Server API's
  # ACL section explicitly lists as MUST-protect. Returns the complete
  # transitive auth chain for the given event (its auth_events plus theirs,
  # recursively — NOT including the event itself), same computation
  # get_state/get_state_ids already do per state event, just entered from
  # a single event_id instead.
  # ---------------------------------------------------------------------------

  def event_auth(conn, %{"room_id" => room_id, "event_id" => event_id}) do
    origin = conn.assigns[:origin_server]

    if acl_allowed?(room_id, origin) do
      case EventStore.get_event(event_id) do
        {:ok, %{room_id: ^room_id} = event} ->
          auth_chain =
            event
            |> get_auth_chain_ids()
            |> Enum.flat_map(fn id ->
              case EventStore.get_event(id) do
                {:ok, e} -> [EventStore.event_to_pdu(e)]
                _ -> []
              end
            end)

          json(conn, %{"auth_chain" => auth_chain})

        _ ->
          conn
          |> put_status(404)
          |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Event not found"})
      end
    else
      acl_forbidden(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/backfill/:room_id
  # ---------------------------------------------------------------------------

  def backfill(conn, %{"room_id" => room_id} = params) do
    origin = conn.assigns[:origin_server]

    if acl_allowed?(room_id, origin) do
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
        "pdus" => Enum.map(events, &EventStore.event_to_pdu/1)
      })
    else
      acl_forbidden(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /_matrix/federation/v1/get_missing_events/:room_id
  # ---------------------------------------------------------------------------

  def get_missing_events(conn, %{"room_id" => room_id} = params) do
    origin = conn.assigns[:origin_server]

    if acl_allowed?(room_id, origin) do
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
        "events" => Enum.map(events, &EventStore.event_to_pdu/1)
      })
    else
      acl_forbidden(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/timestamp_to_event/:room_id
  #
  # Server-server counterpart of the client "jump to date" endpoint (GET
  # /_matrix/client/v1/rooms/:room_id/timestamp_to_event,
  # AxonWeb.EventController.timestamp_to_event/2). A resident server that
  # joined too late to hold history around a given timestamp asks a server
  # that does — this is the side that answers. Same local search
  # (EventStore.find_event_by_timestamp/3) the client endpoint uses, gated
  # by ACL only: unlike the client endpoint there's no membership check,
  # because what's being authorized here is the requesting *server*, same
  # as get_state/get_event/backfill above.
  # ---------------------------------------------------------------------------

  def timestamp_to_event(conn, %{"room_id" => room_id} = params) do
    origin = conn.assigns[:origin_server]

    with {:ok, ts} <- parse_ts_param(params["ts"]),
         {:ok, dir} <- parse_dir_param(params["dir"]) do
      cond do
        not acl_allowed?(room_id, origin) ->
          acl_forbidden(conn)

        event = EventStore.find_event_by_timestamp(room_id, ts, dir) ->
          json(conn, %{
            "event_id" => event.event_id,
            "origin_server_ts" => event.origin_server_ts
          })

        true ->
          conn
          |> put_status(404)
          |> json(%{
            "errcode" => "M_NOT_FOUND",
            "error" => "Unable to find event from #{ts} in direction #{dir}"
          })
      end
    else
      {:error, errcode, message} ->
        conn |> put_status(400) |> json(%{"errcode" => errcode, "error" => message})
    end
  end

  defp parse_ts_param(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, "M_INVALID_PARAM", "Query parameter ts must be a non-negative integer"}
    end
  end

  defp parse_ts_param(_), do: {:error, "M_MISSING_PARAM", "Missing required parameter: ts"}

  defp parse_dir_param(dir) when dir in ["f", "b"], do: {:ok, dir}
  defp parse_dir_param(nil), do: {:ok, "f"}

  defp parse_dir_param(_),
    do: {:error, "M_INVALID_PARAM", "Query parameter dir must be one of \"f\" or \"b\""}

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
    user_id |> AxonCore.MatrixId.server_name() == local_server
  end

  # Guards inbound ephemeral EDUs (m.typing, m.receipt) against a remote
  # server injecting state for a room/user we have no actual relationship
  # with — the claimed user must be a joined member of the room per our own
  # (federation-derived) membership records.
  defp local_room_member?(room_id, user_id) when is_binary(room_id) and is_binary(user_id) do
    EventStore.get_membership(room_id, user_id) == {:ok, "join"}
  end

  defp local_room_member?(_room_id, _user_id), do: false

  defp apply_inbound_receipt(origin, room_id, receipt_type, user_id, receipt_data) do
    sender_server = user_id |> to_string() |> AxonCore.MatrixId.server_name()
    event_id = receipt_data["event_ids"] |> List.wrap() |> List.first()
    ts = get_in(receipt_data, ["data", "ts"]) || System.os_time(:millisecond)

    if sender_server == origin and is_binary(event_id) and local_room_member?(room_id, user_id) and
         acl_allowed?(room_id, origin) do
      Repo.insert_all(
        "receipts",
        [
          %{
            room_id: room_id,
            user_id: user_id,
            receipt_type: receipt_type,
            event_id: event_id,
            ts: ts
          }
        ],
        on_conflict: {:replace, [:event_id, :ts]},
        conflict_target: [:room_id, :user_id, :receipt_type]
      )

      EventStore.record_ephemeral_update(room_id)
    else
      Logger.warning(
        "Dropping m.receipt EDU from #{origin} for room #{inspect(room_id)}, user #{inspect(user_id)}"
      )
    end
  end

  # Silently ignores unrecognized/irrelevant users in the batch — a
  # m.presence push commonly covers many users, and one of them not being
  # anyone we share a room with is normal, not suspicious (unlike a
  # room-scoped m.typing/m.receipt EDU naming a room we have no relation to).
  defp apply_inbound_presence(%{"user_id" => user_id, "presence" => presence} = update, origin)
       when presence in ["online", "unavailable", "offline"] do
    sender_server = user_id |> to_string() |> AxonCore.MatrixId.server_name()

    if sender_server == origin and EventStore.known_user?(user_id) do
      AxonSync.Presence.set_remote(
        user_id,
        presence,
        update["status_msg"],
        update["last_active_ago"]
      )
    end
  end

  defp apply_inbound_presence(_update, _origin), do: :ok

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
      event["state_key"] != event["sender"] -> {:error, :invalid_join}
      true -> :ok
    end
  end

  # send_leave is specifically for a remote user lodging their own
  # departure (make_leave/send_leave only ever build/accept a self-leave —
  # a kick/ban is a *local* action taken by someone with sufficient power,
  # never routed through this endpoint), so state_key must equal sender
  # exactly like join/knock. Previously this endpoint had no type/content
  # validation at all — any signed, auth-valid event (e.g. an ordinary
  # message) from a joined member would be silently accepted and applied.
  defp validate_leave_event(event, room_id) do
    cond do
      event["type"] != "m.room.member" -> {:error, :invalid_leave}
      event["room_id"] != room_id -> {:error, :invalid_leave}
      get_in(event, ["content", "membership"]) != "leave" -> {:error, :invalid_leave}
      event["state_key"] != event["sender"] -> {:error, :invalid_leave}
      true -> :ok
    end
  end

  defp verify_event_signature(event), do: EventVerification.verify_signature(event)

  # See apply_knock_event/3 — must go through RoomProcess.apply_remote_event/3,
  # not a direct EventStore.insert_event, or the room's live GenServer never
  # learns the remote user joined (federation fan-out silently excludes them,
  # /sync doesn't show the join in real time, and their next event over
  # send_transaction gets wrongly auth-rejected as "not_joined" until the
  # room process happens to restart). relay_exclude: origin relays the join
  # on to this room's other resident servers — without it, a room with 3+
  # servers never converges (see apply_remote_event/3's doc).
  defp apply_join_event(room_id, join_event, origin) do
    case RoomProcess.apply_remote_event(room_id, join_event, relay_exclude: origin) do
      {:ok, event_id} -> {:ok, event_id}
      {:error, _reason} -> {:error, :auth_failed}
    end
  end

  # relay_exclude: origin — see apply_join_event/3. A self-leave via
  # send_leave has the exact same "acting server can't fan out to peers it
  # doesn't know" shape as a join.
  defp apply_leave_event(room_id, leave_event, origin) do
    case RoomProcess.apply_remote_event(room_id, leave_event, relay_exclude: origin) do
      {:ok, event_id} -> {:ok, event_id}
      {:error, _reason} -> {:error, :auth_failed}
    end
  end

  defp process_inbound_pdu(pdu, origin) do
    room_id = pdu["room_id"]

    cond do
      not room_exists?(room_id) ->
        # Soft-fail: we don't know this room
        {:error, :unknown_room}

      not acl_allowed?(room_id, origin) ->
        {:error, :acl_denied}

      true ->
        case verify_event_signature(pdu) do
          :ok ->
            apply_remote_event(pdu, room_id, origin)

          {:error, reason} ->
            Logger.warning("Inbound PDU signature failed from #{origin}: #{inspect(reason)}")
            {:error, :bad_signature}
        end
    end
  end

  # If this PDU's prev_events reference events we don't have locally (we
  # missed a transaction, or are catching up after downtime), close that
  # gap via AxonFederation.Backfill *before* auth-checking pdu itself —
  # otherwise AxonRoom.StateResolver silently drops the unknown ancestor
  # branch and auth-checks against incomplete state, which either lets a
  # gap through with wrong resolved state or (more commonly) soft-fails
  # the PDU for good, with no other code path ever retrying it.
  defp apply_remote_event(pdu, room_id, origin) do
    Backfill.catch_up(room_id, origin, pdu)

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

  # m.room.server_acl (Server-Server API "Server Access Control Lists")
  # gating for every federation endpoint the spec lists as MUST-protect,
  # plus the per-PDU/per-EDU checks on /send. Deliberately a network-layer
  # check only (AxonRoom.ServerAcl), not routed through AuthRules — a
  # denied server's already-accepted events/state stay put, only further
  # requests get rejected.
  defp acl_allowed?(room_id, server_name) do
    case EventStore.get_state_event(room_id, "m.room.server_acl", "") do
      {:ok, %{content: content}} -> ServerAcl.allowed_by_content?(content, server_name)
      {:error, :not_found} -> true
    end
  end

  defp check_acl(room_id, server_name) do
    if acl_allowed?(room_id, server_name), do: :ok, else: {:error, :acl_denied}
  end

  defp acl_forbidden(conn) do
    conn
    |> put_status(403)
    |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Server denied by ACL"})
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
      "origin" => user_id |> AxonCore.MatrixId.server_name(),
      "prev_events" => if(room_ctx.last_event_id, do: [room_ctx.last_event_id], else: []),
      "auth_events" =>
        select_join_auth_events(user_id, room_ctx.current_state, room_ctx.room_version),
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
      "origin" => user_id |> AxonCore.MatrixId.server_name(),
      "prev_events" => if(room_ctx.last_event_id, do: [room_ctx.last_event_id], else: []),
      "auth_events" =>
        select_join_auth_events(user_id, room_ctx.current_state, room_ctx.room_version),
      "depth" => room_ctx.depth + 1
    }
  end

  defp select_join_auth_events(user_id, current_state, room_version) do
    # Room v12 (rule 3.2): m.room.create MUST NOT be selected as an auth
    # event for anything — mirrors AxonRoom.EventBuilder.select_auth_events/5,
    # duplicated here because a remote join's template is built without
    # going through the normal local event-build path.
    create_ref =
      if room_version == "12",
        do: [],
        else: [get_in(current_state, [{"m.room.create", ""}, "event_id"])]

    (create_ref ++
       [
         get_in(current_state, [{"m.room.power_levels", ""}, "event_id"]),
         get_in(current_state, [{"m.room.join_rules", ""}, "event_id"]),
         get_in(current_state, [{"m.room.member", user_id}, "event_id"])
       ])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp build_auth_chain_for_state(state_events) do
    state_events
    |> Enum.flat_map(&get_auth_chain_ids/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn event_id ->
      case EventStore.get_event(event_id) do
        {:ok, e} -> [EventStore.event_to_pdu(e)]
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

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/hierarchy/:room_id
  #
  # Server-to-server counterpart of the CS API's /hierarchy. Called by
  # AxonWeb.SpaceController.fetch_remote_entry/3 when a local hierarchy walk
  # reaches a room this server isn't resident in. Contract expected by that
  # caller (do not change field names without updating both sides):
  #
  #   200 {"room" => <summary-map, same field names as the CS API per-room
  #                    entry: room_id, name?, topic?, avatar_url?,
  #                    canonical_alias?, num_joined_members, world_readable,
  #                    guest_can_join, join_rule, room_type?, room_version,
  #                    encryption?, allowed_room_ids?, children_state>,
  #        "children" => [<same-shaped summaries for this room's own
  #                        immediate space-children, no further nesting>],
  #        "inaccessible_children" => [<room_id, ...>]}
  #   404 {"errcode" => "M_NOT_FOUND", ...} — room doesn't exist locally, or
  #        isn't visible to this origin server at all (not public/world-
  #        readable, and the origin has no user satisfying a restricted
  #        room's allow-list).
  #   403 — origin is ACL-denied (mirror the acl_allowed?/acl_forbidden
  #        pattern used by event_auth/backfill/etc. in this same file).
  #
  # Unlike the CS API version, there's no specific requesting *user* — only
  # a requesting *server* (the X-Matrix-authenticated `origin`). A
  # restricted room's allow-list is satisfied here if origin has *any* user
  # joined to one of the allow-listed rooms, checked against this server's
  # own local room_memberships for that room (only meaningful if this
  # server happens to be resident there — see TestRestrictedRoomsSpacesSummaryFederation's
  # own comment: hs2 only learns hs1 has a member of the space once *some*
  # hs2 user joins the space and hs2 becomes resident in it).
  # ---------------------------------------------------------------------------

  def hierarchy(conn, %{"room_id" => room_id} = params) do
    origin = conn.assigns[:origin_server]
    suggested_only = params["suggested_only"] in ["true", true]

    cond do
      not acl_allowed?(room_id, origin) ->
        acl_forbidden(conn)

      not room_exists?(room_id) ->
        hierarchy_not_found(conn)

      not server_may_see?(room_id, origin) ->
        hierarchy_not_found(conn)

      true ->
        children = hierarchy_child_events(room_id, suggested_only)
        room = hierarchy_build_entry(room_id, children)

        child_summaries =
          children
          |> Enum.map(& &1["state_key"])
          |> Enum.filter(&room_exists?/1)
          |> Enum.filter(&server_may_see?(&1, origin))
          |> Enum.map(fn child_id ->
            hierarchy_build_entry(child_id, hierarchy_child_events(child_id, suggested_only))
          end)

        inaccessible =
          children
          |> Enum.map(& &1["state_key"])
          |> Enum.reject(fn child_id ->
            room_exists?(child_id) and server_may_see?(child_id, origin)
          end)

        json(conn, %{
          "room" => room,
          "children" => child_summaries,
          "inaccessible_children" => inaccessible
        })
    end
  end

  defp hierarchy_not_found(conn) do
    conn
    |> put_status(404)
    |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found or not accessible"})
  end

  # A room is visible to a requesting *server* if it's public/knock-joinable,
  # world-readable, or — for a restricted room — origin has a locally-known
  # member (per this server's own state) in one of the allow-listed rooms.
  defp server_may_see?(room_id, origin) do
    state = hierarchy_state_map(room_id, ["m.room.join_rules", "m.room.history_visibility"])
    join_rule = get_in(state, ["m.room.join_rules", "join_rule"])
    history_visibility = get_in(state, ["m.room.history_visibility", "history_visibility"])

    join_rule in ["public", "knock"] or history_visibility == "world_readable" or
      (join_rule in ["restricted", "knock_restricted"] and
         restricted_allow_satisfied_by_server?(state, origin))
  end

  defp restricted_allow_satisfied_by_server?(state, origin) do
    allow = get_in(state, ["m.room.join_rules", "allow"]) || []

    allow
    |> Enum.filter(&(&1["type"] == "m.room_membership"))
    |> Enum.map(& &1["room_id"])
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&any_local_member_from_server?(&1, origin))
  end

  defp any_local_member_from_server?(room_id, origin) do
    Repo.exists?(
      from(m in "room_memberships",
        where: m.room_id == ^room_id and m.membership == "join",
        where: fragment("split_part(?, ':', 2)", m.user_id) == ^origin
      )
    )
  end

  defp room_exists?(room_id) do
    Repo.one(from(r in "rooms", where: r.room_id == ^room_id, select: 1)) != nil
  end

  defp hierarchy_state_map(room_id, types) do
    Repo.all(
      from(s in "current_room_state",
        join: e in "events",
        on: e.event_id == s.event_id,
        where: s.room_id == ^room_id and s.type in ^types,
        select: %{type: s.type, content: e.content}
      )
    )
    |> Enum.into(%{}, fn r -> {r.type, r.content} end)
  end

  defp hierarchy_child_events(room_id, suggested_only) do
    rows =
      Repo.all(
        from(s in "current_room_state",
          join: e in "events",
          on: e.event_id == s.event_id,
          where: s.room_id == ^room_id and s.type == "m.space.child",
          select: %{
            state_key: s.state_key,
            content: e.content,
            sender: e.sender,
            origin_server_ts: e.origin_server_ts
          }
        )
      )
      |> Enum.reject(&(&1.content == %{} or &1.content == nil))

    rows =
      if suggested_only,
        do: Enum.filter(rows, &(get_in(&1.content, ["suggested"]) == true)),
        else: rows

    Enum.map(rows, fn r ->
      %{
        "type" => "m.space.child",
        "state_key" => r.state_key,
        "content" => r.content,
        "sender" => r.sender,
        "origin_server_ts" => r.origin_server_ts
      }
    end)
  end

  defp hierarchy_build_entry(room_id, children) do
    state =
      hierarchy_state_map(room_id, [
        "m.room.name",
        "m.room.topic",
        "m.room.avatar",
        "m.room.canonical_alias",
        "m.room.history_visibility",
        "m.room.guest_access",
        "m.room.join_rules",
        "m.room.create",
        "m.room.encryption"
      ])

    num_joined =
      Repo.one(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.membership == "join",
          select: count(m.user_id)
        )
      ) || 0

    room_type = get_in(state, ["m.room.create", "type"])
    guest_access = get_in(state, ["m.room.guest_access", "guest_access"]) || "forbidden"

    history_visibility =
      get_in(state, ["m.room.history_visibility", "history_visibility"]) || "shared"

    join_rule = get_in(state, ["m.room.join_rules", "join_rule"]) || "invite"

    room_version =
      Repo.one(from(r in "rooms", where: r.room_id == ^room_id, select: r.version)) || "1"

    entry = %{
      "room_id" => room_id,
      "num_joined_members" => num_joined,
      "world_readable" => history_visibility == "world_readable",
      "guest_can_join" => guest_access == "can_join",
      "join_rule" => join_rule,
      "room_version" => room_version,
      "children_state" => children
    }

    entry =
      Enum.reduce(
        [
          {get_in(state, ["m.room.name", "name"]), "name"},
          {get_in(state, ["m.room.topic", "topic"]), "topic"},
          {get_in(state, ["m.room.avatar", "url"]), "avatar_url"},
          {get_in(state, ["m.room.canonical_alias", "alias"]), "canonical_alias"},
          {room_type, "room_type"},
          {get_in(state, ["m.room.encryption", "algorithm"]), "encryption"}
        ],
        entry,
        fn
          {nil, _k}, acc -> acc
          {v, k}, acc -> Map.put(acc, k, v)
        end
      )

    if join_rule in ["restricted", "knock_restricted"] do
      allow = get_in(state, ["m.room.join_rules", "allow"]) || []

      ids =
        allow
        |> Enum.filter(&(&1["type"] == "m.room_membership"))
        |> Enum.map(& &1["room_id"])
        |> Enum.reject(&is_nil/1)

      if ids == [], do: entry, else: Map.put(entry, "allowed_room_ids", ids)
    else
      entry
    end
  end
end
