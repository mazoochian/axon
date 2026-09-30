defmodule AxonWeb.FederationController do
  @moduledoc """
  Inbound Server-Server API handlers.

  All routes are authenticated via X-Matrix header (AxonWeb.Plug.FederationAuth).
  """

  use Phoenix.Controller, formats: [:json]

  import Ecto.Query, only: [from: 2]
  import AxonCore.MapUtil, only: [maybe_put: 3]
  alias AxonCore.{EventStore, KeyStore, Repo}
  alias AxonCore.Schema.Event
  alias AxonCrypto.{EventHash, KeyServer}
  alias AxonRoom.{RestrictedJoin, RoomProcess, ServerAcl}
  alias AxonFederation.{Backfill, EventVerification}
  alias AxonWeb.{EventController, Params}
  require Logger

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/make_join/:room_id/:user_id
  # ---------------------------------------------------------------------------

  def make_join(conn, %{"room_id" => room_id, "user_id" => user_id}) do
    with {:ok, room_ctx, version} <-
           prepare_make_membership(conn, room_id, user_id, supported_room_versions(conn)),
         {:ok, member_content} <- join_member_content(room_ctx.current_state, user_id) do
      json(conn, %{
        "room_version" => version,
        "event" => membership_template(room_id, room_ctx, user_id, member_content)
      })
    else
      {:error, reason} -> render_error(conn, reason)
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
        {:error, :join_not_allowed}

      sender_membership in ["invite", "join"] ->
        {:ok, %{"membership" => "join"}}

      join_rule in ["public", "open"] ->
        {:ok, %{"membership" => "join"}}

      join_rule in ["restricted", "knock_restricted"] ->
        join_rule_content = (join_rule_event && join_rule_event["content"]) || %{}

        case RestrictedJoin.authorise(join_rule_content, user_id, current_state) do
          {:ok, authoriser} ->
            {:ok, %{"membership" => "join", "join_authorised_via_users_server" => authoriser}}

          {:error, _} ->
            {:error, :join_not_allowed}
        end

      true ->
        {:error, :join_not_allowed}
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /_matrix/federation/v2/send_join/:room_id/:event_id
  # PUT /_matrix/federation/v1/send_join/:room_id/:event_id (deprecated)
  # ---------------------------------------------------------------------------

  def send_join(conn, params), do: respond(conn, do_send_join(conn, params))

  def send_join_v1(conn, params), do: respond_v1(conn, do_send_join(conn, params))

  # The request body IS the join event (room_id/event_id are legitimate
  # event fields, not just routing params to be stripped).
  defp do_send_join(conn, %{"room_id" => room_id} = join_event) do
    join_event = countersign_restricted_join(join_event, room_id)

    with {:ok, event_id} <- receive_membership_event(conn, join_event, "join") do
      state_events = EventStore.get_current_state(room_id)

      {:ok,
       %{
         "origin" => KeyServer.server_name(),
         "auth_chain" => auth_chain_pdus(state_events),
         "state" => Enum.map(state_events, &EventStore.event_to_pdu/1),
         "event" => EventStore.event_to_pdu_by_id(event_id)
       }}
    end
  end

  defp countersign_restricted_join(
         %{"content" => %{"join_authorised_via_users_server" => authoriser}} = event,
         room_id
       )
       when is_binary(authoriser) do
    if AxonCore.MatrixId.server_name(authoriser) == KeyServer.server_name(),
      do: KeyServer.sign_event(event, EventStore.get_room_version(room_id, "11")),
      else: event
  end

  defp countersign_restricted_join(event, _room_id), do: event

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/make_leave/:room_id/:user_id
  # ---------------------------------------------------------------------------

  def make_leave(conn, %{"room_id" => room_id, "user_id" => user_id}) do
    case prepare_make_membership(conn, room_id, user_id, :any) do
      {:ok, room_ctx, version} ->
        json(conn, %{
          "room_version" => version,
          "event" => membership_template(room_id, room_ctx, user_id, %{"membership" => "leave"})
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /_matrix/federation/v2/send_leave/:room_id/:event_id
  # PUT /_matrix/federation/v1/send_leave/:room_id/:event_id (deprecated)
  # ---------------------------------------------------------------------------

  def send_leave(conn, params), do: respond(conn, do_send_leave(conn, params))

  def send_leave_v1(conn, params), do: respond_v1(conn, do_send_leave(conn, params))

  defp do_send_leave(conn, leave_event) do
    with {:ok, _event_id} <- receive_membership_event(conn, leave_event, "leave") do
      {:ok, %{}}
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /_matrix/federation/v2/invite/:room_id/:event_id
  # PUT /_matrix/federation/v1/invite/:room_id/:event_id (deprecated)
  #
  # A remote resident server inviting one of our local users. Unlike
  # make_join/send_join, we don't (and structurally can't) already have
  # this room's state: we may be seeing it for the very first time. We
  # don't become resident just from an invite — only the bare membership
  # row plus the sender's `invite_room_state` preview are stored, exactly
  # enough for /sync's invite_state (AxonWeb.SyncHelpers.build_invite_state/2)
  # to show something and for AxonFederation.RoomLeave to reject it later.
  # ---------------------------------------------------------------------------

  def invite(conn, %{"room_id" => room_id} = params) do
    respond(
      conn,
      do_invite(
        conn,
        room_id,
        params["event"],
        params["room_version"] || "11",
        params["invite_room_state"] || []
      )
    )
  end

  # v1 carries the bare event as the body, with the stripped state preview
  # in its `unsigned`, and is only used for room versions 1 and 2.
  def invite_v1(conn, %{"room_id" => room_id} = event) do
    respond_v1(
      conn,
      do_invite(
        conn,
        room_id,
        event,
        EventStore.get_room_version(room_id, "1"),
        get_in(event, ["unsigned", "invite_room_state"]) || []
      )
    )
  end

  defp do_invite(conn, room_id, event, room_version, invite_room_state) do
    origin = conn.assigns[:origin_server]

    with :ok <- check_acl(room_id, origin),
         :ok <- validate_invite_event(event, room_id, origin),
         {:ok, signed_event} <- accept_invite(room_id, room_version, event, invite_room_state) do
      {:ok, %{"event" => signed_event}}
    end
  end

  defp validate_invite_event(event, room_id, origin) when is_map(event) do
    local_server = KeyServer.server_name()
    target_server = event["state_key"] |> to_string() |> AxonCore.MatrixId.server_name()
    sender_server = event["sender"] |> to_string() |> AxonCore.MatrixId.server_name()

    cond do
      event["type"] != "m.room.member" -> {:error, {:invalid_event, "invite"}}
      event["room_id"] != room_id -> {:error, {:invalid_event, "invite"}}
      get_in(event, ["content", "membership"]) != "invite" -> {:error, {:invalid_event, "invite"}}
      target_server != local_server -> {:error, {:invalid_event, "invite"}}
      sender_server != origin -> {:error, {:invalid_event, "invite"}}
      true -> :ok
    end
  end

  defp validate_invite_event(_event, _room_id, _origin), do: {:error, {:invalid_event, "invite"}}

  defp accept_invite(room_id, room_version, event, invite_room_state) do
    signed_event =
      event
      |> KeyServer.sign_event(room_version)
      |> ensure_event_id(room_version)

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

    with {:ok, _persisted} <- EventStore.insert_event(signed_event, room_version) do
      EventStore.set_invite_preview_state(room_id, signed_event["state_key"], invite_room_state)
      {:ok, signed_event}
    end
  end

  # Room versions 3+ never carry "event_id" on the wire (it's derived from
  # the reference hash) — the inviting server's event has none, and signing
  # it here doesn't add one either. Without this, EventStore.insert_event/2
  # gets a nil event_id and the changeset's NOT NULL violation surfaces as
  # an opaque 500 to the inviting server.
  defp ensure_event_id(%{"event_id" => id} = event, _room_version) when is_binary(id), do: event

  defp ensure_event_id(event, room_version) do
    Map.put(event, "event_id", EventHash.reference_hash(event, room_version))
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/make_knock/:room_id/:user_id
  # ---------------------------------------------------------------------------

  def make_knock(conn, %{"room_id" => room_id, "user_id" => user_id}) do
    with {:ok, room_ctx, version} <-
           prepare_make_membership(conn, room_id, user_id, supported_room_versions(conn)),
         :ok <- check_knockable(room_ctx.current_state) do
      json(conn, %{
        "room_version" => version,
        "event" => membership_template(room_id, room_ctx, user_id, %{"membership" => "knock"})
      })
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp check_knockable(current_state) do
    join_rule = get_in(current_state[{"m.room.join_rules", ""}], ["content", "join_rule"])
    if join_rule in ["knock", "knock_restricted"], do: :ok, else: {:error, :knock_not_allowed}
  end

  # ---------------------------------------------------------------------------
  # PUT /_matrix/federation/v1/send_knock/:room_id/:event_id
  # ---------------------------------------------------------------------------

  def send_knock(conn, %{"room_id" => room_id} = knock_event) do
    result =
      with {:ok, _event_id} <- receive_membership_event(conn, knock_event, "knock") do
        {:ok, %{"knock_room_state" => EventStore.stripped_state_events(room_id)}}
      end

    respond(conn, result)
  end

  # ---------------------------------------------------------------------------
  # Helpers — make_*/send_* membership handshakes
  # ---------------------------------------------------------------------------

  # Every value of the repeatable `ver` query parameter; the spec default
  # when the caller sends none is room version 1 only.
  defp supported_room_versions(conn) do
    case Params.query_values(conn, "ver") do
      [] -> ["1"]
      versions -> versions
    end
  end

  defp prepare_make_membership(conn, room_id, user_id, supported_versions) do
    origin = conn.assigns[:origin_server]

    cond do
      AxonCore.MatrixId.server_name(user_id) != origin ->
        {:error, :origin_mismatch}

      not EventStore.room_exists?(room_id) ->
        {:error, :room_not_found}

      not acl_allowed?(room_id, origin) ->
        {:error, :acl_denied}

      true ->
        version = EventStore.get_room_version(room_id)

        if supported_versions == :any or version in supported_versions,
          do: {:ok, RoomProcess.get_room_ctx(room_id), version},
          else: {:error, {:incompatible_room_version, version}}
    end
  end

  # Partial membership event (no hashes/signatures — the remote fills those in).
  defp membership_template(room_id, room_ctx, user_id, content) do
    %{
      "type" => "m.room.member",
      "room_id" => room_id,
      "sender" => user_id,
      "state_key" => user_id,
      "content" => content,
      "origin_server_ts" => System.os_time(:millisecond),
      "origin" => AxonCore.MatrixId.server_name(user_id),
      "prev_events" => if(room_ctx.last_event_id, do: [room_ctx.last_event_id], else: []),
      "auth_events" =>
        select_join_auth_events(user_id, room_ctx.current_state, room_ctx.room_version),
      "depth" => room_ctx.depth + 1
    }
  end

  defp receive_membership_event(conn, %{"room_id" => room_id} = event, membership) do
    origin = conn.assigns[:origin_server]

    with :ok <- check_acl(room_id, origin),
         :ok <- validate_membership_event(event, room_id, origin, membership),
         :ok <- verify_event_signature(event) do
      apply_membership_event(room_id, event, origin)
    end
  end

  # send_join/send_leave/send_knock only ever accept a self-targeted
  # membership of the endpoint's own kind (a kick/ban is a local action,
  # never routed through these). `origin` (the authenticated X-Matrix
  # caller) must be the same server as the event's own `sender` — otherwise
  # any federating server could relay another server's membership event to
  # us untouched except for its unsigned `displayname`/`avatar_url` fields
  # (both dropped by redaction, so the signature doesn't cover them),
  # impersonating the user's profile without ever holding their key.
  defp validate_membership_event(event, room_id, origin, membership) do
    sender_server = event["sender"] |> to_string() |> AxonCore.MatrixId.server_name()

    if event["type"] == "m.room.member" and event["room_id"] == room_id and
         get_in(event, ["content", "membership"]) == membership and
         event["state_key"] == event["sender"] and sender_server == origin,
       do: :ok,
       else: {:error, {:invalid_event, membership}}
  end

  # Must go through RoomProcess.apply_remote_event/3, not a direct
  # EventStore.insert_event, or the room's live GenServer never learns
  # about the membership change (fan-out, /sync and later auth checks all
  # go stale). relay_exclude: origin — this resident server is the only
  # one positioned to relay the event on to every OTHER server with a
  # member in the room; without it a room with 3+ servers never converges.
  defp apply_membership_event(room_id, event, origin) do
    case RoomProcess.apply_remote_event(room_id, event, relay_exclude: origin) do
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
    pdus = list_param(params["pdus"])
    edus = list_param(params["edus"])

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
        Enum.flat_map(pdus, fn pdu ->
          case inbound_event_id(pdu) do
            {:ok, event_id} ->
              [
                {event_id,
                 pdu_result(process_inbound_pdu(Map.put(pdu, "event_id", event_id), origin))}
              ]

            {:error, nil, reason} ->
              Logger.warning("Dropping unidentifiable PDU from #{origin}: #{inspect(reason)}")
              []

            {:error, key, reason} ->
              [{key, pdu_result({:error, reason})}]
          end
        end)
        |> Map.new()

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

  defp list_param(list) when is_list(list), do: list
  defp list_param(_), do: []

  defp pdu_result(:ok), do: %{}
  defp pdu_result({:error, reason}), do: %{"error" => inspect(reason)}

  # Room versions 1 and 2 carry their event_id on the wire. From version 3
  # on it is the reference hash, always computed here; a wire event_id that
  # disagrees is rejected rather than trusted. Returns the key to report an
  # error under (nil when the PDU can't be identified at all).
  defp inbound_event_id(%{"room_id" => room_id} = pdu) when is_binary(room_id) do
    wire_id = pdu["event_id"]

    case EventStore.get_room_version(room_id) do
      version when version in ["1", "2"] ->
        if is_binary(wire_id), do: {:ok, wire_id}, else: {:error, nil, :missing_event_id}

      version ->
        case safe_reference_hash(pdu, version) do
          {:ok, computed} when wire_id in [nil, computed] -> {:ok, computed}
          {:ok, _computed} when is_binary(wire_id) -> {:error, wire_id, :event_id_mismatch}
          {:ok, computed} -> {:error, computed, :event_id_mismatch}
          :error when is_binary(wire_id) -> {:error, wire_id, :invalid_pdu}
          :error -> {:error, nil, :invalid_pdu}
        end
    end
  end

  defp inbound_event_id(%{"event_id" => wire_id}) when is_binary(wire_id),
    do: {:error, wire_id, :invalid_pdu}

  defp inbound_event_id(_pdu), do: {:error, nil, :invalid_pdu}

  defp safe_reference_hash(pdu, version) do
    {:ok, EventHash.reference_hash(pdu, version)}
  rescue
    ArgumentError -> :error
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
    origin = conn.assigns[:origin_server]

    with {:ok, event} <- fetch_event(event_id),
         :ok <- authorize_room_read(event.room_id, origin) do
      json(conn, %{
        "origin" => KeyServer.server_name(),
        "origin_server_ts" => event.origin_server_ts,
        "pdus" => pdus_for_origin([event], event.room_id, origin)
      })
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/state/:room_id?event_id=...
  # ---------------------------------------------------------------------------

  def get_state(conn, %{"room_id" => room_id} = params) do
    case state_at_event(conn, room_id, params["event_id"]) do
      {:ok, state_events} ->
        json(conn, %{
          "pdus" => Enum.map(state_events, &EventStore.event_to_pdu/1),
          "auth_chain" => auth_chain_pdus(state_events)
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/state_ids/:room_id?event_id=...
  # ---------------------------------------------------------------------------

  def get_state_ids(conn, %{"room_id" => room_id} = params) do
    case state_at_event(conn, room_id, params["event_id"]) do
      {:ok, state_events} ->
        json(conn, %{
          "pdu_ids" => Enum.map(state_events, & &1.event_id),
          "auth_chain_ids" => auth_chain_ids(state_events)
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  # The room state *before* `event_id` (the event itself excluded), same as
  # the reference implementations answer these two endpoints.
  defp state_at_event(conn, room_id, event_id) do
    with :ok <- authorize_room_read(room_id, conn.assigns[:origin_server]),
         {:ok, event} <- fetch_room_event(room_id, event_id) do
      {:ok, EventStore.get_room_state_at(room_id, event.stream_ordering - 1)}
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/event_auth/:room_id/:event_id
  #
  # The complete transitive auth chain for the given event (its
  # auth_events plus theirs, recursively — NOT including the event itself).
  # ---------------------------------------------------------------------------

  def event_auth(conn, %{"room_id" => room_id, "event_id" => event_id}) do
    with :ok <- authorize_room_read(room_id, conn.assigns[:origin_server]),
         {:ok, event} <- fetch_room_event(room_id, event_id) do
      json(conn, %{"auth_chain" => auth_chain_pdus([event])})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/backfill/:room_id?v=...&v=...&limit=...
  #
  # The `v` events themselves plus their ancestors, walking prev_events
  # backwards, up to `limit` events.
  # ---------------------------------------------------------------------------

  @max_backfill_limit 100

  def backfill(conn, %{"room_id" => room_id} = params) do
    origin = conn.assigns[:origin_server]
    limit = Params.int(params["limit"], @max_backfill_limit, 1, @max_backfill_limit)

    with :ok <- authorize_room_read(room_id, origin),
         {:ok, from_ids} <- required_query_values(conn, "v") do
      events = walk_prev_events(room_id, from_ids, MapSet.new(), limit, MapSet.new())

      json(conn, %{
        "origin" => KeyServer.server_name(),
        "origin_server_ts" => System.os_time(:millisecond),
        "pdus" => pdus_for_origin(events, room_id, origin)
      })
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp required_query_values(conn, key) do
    case Params.query_values(conn, key) do
      [] -> {:error, {:missing_param, key}}
      values -> {:ok, values}
    end
  end

  # ---------------------------------------------------------------------------
  # POST /_matrix/federation/v1/get_missing_events/:room_id
  # ---------------------------------------------------------------------------

  @max_missing_events_limit 100

  def get_missing_events(conn, %{"room_id" => room_id} = params) do
    origin = conn.assigns[:origin_server]

    case authorize_room_read(room_id, origin) do
      :ok ->
        earliest_events = MapSet.new(list_param(params["earliest_events"]))
        latest_events = list_param(params["latest_events"])
        limit = Params.int(params["limit"], 10, 0, @max_missing_events_limit)

        # Per spec: "a breadth first walk of the prev_events for
        # latest_events" — latest_events are events the requester already
        # has, so the walk starts at *their* prev_events, and they go into
        # `seen` up front so a diamond in the DAG can't emit them either.
        seed_prev_events =
          latest_events
          |> Enum.flat_map(fn event_id ->
            case Repo.get_by(Event, event_id: event_id, room_id: room_id) do
              nil -> []
              event -> event.prev_event_ids
            end
          end)

        events =
          walk_prev_events(
            room_id,
            seed_prev_events,
            earliest_events,
            limit,
            MapSet.new(latest_events)
          )

        json(conn, %{"events" => pdus_for_origin(events, room_id, origin)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  # Breadth-first walk backwards through prev_events from `queue`,
  # collecting up to `limit` events, without stepping past `stop_at`
  # (excluded from the result, and its ancestors are never visited). Not a
  # stream_ordering range scan: the caller names a specific slice of the
  # DAG, and an unrelated event from elsewhere in the room's history must
  # never be returned.
  #
  # `acc` is built by prepending each event as it's visited, so the result
  # comes out earliest to latest without an explicit reverse.
  defp walk_prev_events(room_id, queue, stop_at, limit, seen, acc \\ [])

  defp walk_prev_events(_room_id, [], _stop_at, _limit, _seen, acc), do: acc

  defp walk_prev_events(_room_id, _queue, _stop_at, limit, _seen, acc)
       when length(acc) >= limit,
       do: acc

  defp walk_prev_events(room_id, [event_id | rest], stop_at, limit, seen, acc) do
    event =
      not MapSet.member?(seen, event_id) and not MapSet.member?(stop_at, event_id) and
        Repo.get_by(Event, event_id: event_id, room_id: room_id)

    case event do
      %Event{} ->
        walk_prev_events(
          room_id,
          rest ++ event.prev_event_ids,
          stop_at,
          limit,
          MapSet.put(seen, event_id),
          [event | acc]
        )

      _ ->
        walk_prev_events(room_id, rest, stop_at, limit, seen, acc)
    end
  end

  # Every backfill-shaped response fills gaps in a REMOTE server's copy of
  # the DAG, so each event's history_visibility is judged against that
  # origin server, not against local room membership. An event outside
  # what the origin may see comes back redacted, never omitted: dropping it
  # would break prev_events continuity on the other end.
  defp pdus_for_origin(events, room_id, origin) do
    room_version = EventStore.get_room_version(room_id)
    origin_bounds = origin_visibility_bounds(room_id, origin)

    Enum.map(events, fn event ->
      pdu = EventStore.event_to_pdu(event)

      if Enum.any?(origin_bounds, &EventController.event_visible?(&1, event)),
        do: pdu,
        else: AxonCrypto.Redaction.redact(pdu, room_version)
    end)
  end

  # `AxonWeb.EventController.visibility_bounds/2` was built for a single
  # local user (GET /event, /messages, /sync). Federation needs the same
  # decision made for a whole *server*: history_visibility is per-event,
  # but "can this origin see it" has to be judged against whichever of the
  # origin's own users has been in the room the longest, since any one of
  # them having visibility is enough (mirrors the reference
  # `filter_events_for_server` shape — union of visibility over the
  # server's own members, not just its "current" one).
  #
  # Bounds are computed once per request, not once per event.
  #
  # A synthetic never-a-member id is always included alongside any real
  # members found, so a `world_readable` room answers correctly even for
  # an origin with no member in the room at all.
  defp origin_visibility_bounds(room_id, origin) do
    real_member_ids =
      Repo.all(from(m in "room_memberships", where: m.room_id == ^room_id, select: m.user_id))
      |> Enum.filter(&(AxonCore.MatrixId.server_name(&1) == origin))

    ([synthetic_non_member_id(origin)] ++ real_member_ids)
    |> Enum.uniq()
    |> Enum.map(&EventController.visibility_bounds(room_id, &1))
  end

  defp synthetic_non_member_id(origin), do: "@_get_missing_events_probe:#{origin}"

  # Gate for the endpoints that read room history/state on behalf of a
  # remote server: the room must exist here, the origin must pass the
  # room's ACL, and it must currently have a joined member in the room.
  defp authorize_room_read(room_id, origin) do
    cond do
      not EventStore.room_exists?(room_id) -> {:error, :room_not_found}
      not acl_allowed?(room_id, origin) -> {:error, :acl_denied}
      not server_joined?(room_id, origin) -> {:error, :not_in_room}
      true -> :ok
    end
  end

  # Compares the full server name (everything after the user ID's first
  # colon), so a server name carrying a port matches correctly.
  defp server_joined?(room_id, server_name) do
    Repo.exists?(
      from(m in "room_memberships",
        where: m.room_id == ^room_id and m.membership == "join",
        where: fragment("substr(?, strpos(?, ':') + 1)", m.user_id, m.user_id) == ^server_name
      )
    )
  end

  defp fetch_event(event_id) do
    case EventStore.get_event(event_id) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> {:error, :event_not_found}
    end
  end

  defp fetch_room_event(_room_id, nil), do: {:error, {:missing_param, "event_id"}}

  defp fetch_room_event(room_id, event_id) do
    case fetch_event(event_id) do
      {:ok, %Event{room_id: ^room_id} = event} -> {:ok, event}
      _ -> {:error, :event_not_found}
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
  # by ACL only.
  # ---------------------------------------------------------------------------

  def timestamp_to_event(conn, %{"room_id" => room_id} = params) do
    origin = conn.assigns[:origin_server]

    with {:ok, ts} <- Params.timestamp(params["ts"]),
         {:ok, dir} <- Params.direction(params["dir"]) do
      cond do
        not acl_allowed?(room_id, origin) ->
          render_error(conn, :acl_denied)

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
    server = AxonCore.MatrixId.server_name(user_id)

    if is_nil(server) or not AxonCore.MatrixId.valid_server_name?(server) do
      conn
      |> put_status(400)
      |> json(%{"errcode" => "M_INVALID_PARAM", "error" => "Invalid user_id"})
    else
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
      one_time_keys_request
      |> Enum.map(fn {user_id, device_map} ->
        device_result =
          if local_user?(user_id, local_server) do
            claim_devices(user_id, device_map)
          else
            %{}
          end

        {user_id, device_result}
      end)
      # A user with nothing actually claimed must be absent from the
      # response entirely, not present with an empty device map —
      # Complement's TestFederationKeyUploadQuery checks the *key* for an
      # exhausted user is missing, not merely empty.
      |> Enum.reject(fn {_user_id, device_result} -> device_result == %{} end)
      |> Map.new()

    json(conn, %{"one_time_keys" => result})
  end

  defp claim_devices(user_id, device_map) do
    device_map
    |> Enum.map(fn {device_id, algorithm} ->
      {device_id, KeyStore.claim_one_time_key(user_id, device_id, algorithm)}
    end)
    |> Enum.reject(fn {_device_id, key} -> is_nil(key) end)
    |> Map.new()
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
  # GET /_matrix/federation/v1/openid/userinfo
  #
  # Deliberately outside the X-Matrix-authenticated `:federation` scope
  # (see router.ex, same reasoning as `federation_version/2` above) — the
  # caller here is typically an identity server, not another Matrix
  # server, verifying an OpenID token a client (or, for
  # `AxonWeb.IdentityServer.ensure_access_token/2`'s self-registration
  # fallback, this server acting on a client's behalf) minted via
  # `POST /_matrix/client/v3/user/:user_id/openid/request_token` and
  # handed to it. Per spec this is the *only* check identity servers do
  # before trusting `sub` as this user's real Matrix ID.
  # ---------------------------------------------------------------------------

  def openid_userinfo(conn, params) do
    case params["access_token"] && AxonWeb.OpenidTokens.verify(params["access_token"]) do
      {:ok, user_id} ->
        json(conn, %{"sub" => user_id})

      _ ->
        conn
        |> put_status(401)
        |> json(%{"errcode" => "M_UNKNOWN_TOKEN", "error" => "Invalid or expired OpenID token"})
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers — event verification & application
  # ---------------------------------------------------------------------------

  # The room version drives redaction, which drives what was actually signed.
  defp verify_event_signature(event),
    do: EventVerification.verify_signature(event, EventStore.get_room_version(event["room_id"]))

  # Signature *and* content hash, for the one path where an event can have
  # been relayed by a server other than its author: a PDU in a /send
  # transaction. Returns the event to actually apply — the redacted form
  # when the content hash didn't check out, per the spec's
  # checks-on-receipt ordering. See AxonFederation.EventVerification.verify/2.
  #
  # send_join/send_leave/send_knock deliberately keep the signature-only
  # check above: those carry an event the calling server itself authored,
  # handed to us directly with no relay in between, so the "a middleman
  # rewrote the body" threat this closes doesn't arise there — and
  # redacting a join would silently drop the joiner's displayname/avatar
  # off their membership event.
  defp verify_event(event),
    do: EventVerification.verify(event, EventStore.get_room_version(event["room_id"]))

  defp process_inbound_pdu(pdu, origin) do
    room_id = pdu["room_id"]

    cond do
      not EventStore.room_exists?(room_id) ->
        {:error, :unknown_room}

      not acl_allowed?(room_id, origin) ->
        {:error, :acl_denied}

      true ->
        case verify_event(pdu) do
          # `verified` is `pdu` itself, or its redacted form if the content
          # hash didn't match — apply what came back, never the original.
          {:ok, verified} ->
            apply_remote_event(verified, room_id, origin)

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

  # ---------------------------------------------------------------------------
  # Helpers — responses
  # ---------------------------------------------------------------------------

  defp respond(conn, {:ok, body}), do: json(conn, body)
  defp respond(conn, {:error, reason}), do: render_error(conn, reason)

  # The deprecated v1 send_join/send_leave/invite wrap a success body as
  # `[200, body]`.
  defp respond_v1(conn, {:ok, body}), do: json(conn, [200, body])
  defp respond_v1(conn, error), do: respond(conn, error)

  defp render_error(conn, {:incompatible_room_version, version}) do
    conn
    |> put_status(400)
    |> json(%{
      "errcode" => "M_INCOMPATIBLE_ROOM_VERSION",
      "error" => "Your homeserver does not support the features required to join this room",
      "room_version" => version
    })
  end

  defp render_error(conn, reason) do
    {status, errcode, message} = error_info(reason)
    conn |> put_status(status) |> json(%{"errcode" => errcode, "error" => message})
  end

  defp error_info(:acl_denied), do: {403, "M_FORBIDDEN", "Server denied by ACL"}
  defp error_info(:not_in_room), do: {403, "M_FORBIDDEN", "Server is not in the room"}
  defp error_info(:room_not_found), do: {404, "M_NOT_FOUND", "Room not found"}
  defp error_info(:event_not_found), do: {404, "M_NOT_FOUND", "Event not found"}
  defp error_info(:join_not_allowed), do: {403, "M_FORBIDDEN", "Join not allowed"}
  defp error_info(:auth_failed), do: {403, "M_FORBIDDEN", "Event failed auth check"}

  defp error_info(:origin_mismatch),
    do: {403, "M_FORBIDDEN", "User ID domain does not match origin"}

  defp error_info(:knock_not_allowed),
    do: {403, "M_FORBIDDEN", "This room does not support knocking"}

  defp error_info({:invalid_event, membership}),
    do: {400, "M_BAD_JSON", "Invalid #{membership} event"}

  defp error_info({:missing_param, name}),
    do: {400, "M_MISSING_PARAM", "Missing required parameter: #{name}"}

  # Distinct messages per reason: these three fail for completely different
  # operational causes (bad crypto vs an unsigned event vs not being able to
  # fetch the origin's keys at all).
  defp error_info(:bad_signature), do: {403, "M_FORBIDDEN", "Bad event signature"}

  defp error_info(:missing_signature),
    do: {403, "M_FORBIDDEN", "Event has no signature from its origin server"}

  defp error_info(:key_not_found),
    do: {403, "M_FORBIDDEN", "Could not fetch the origin server's signing key"}

  defp error_info(_), do: {500, "M_UNKNOWN", "Internal error"}

  # ---------------------------------------------------------------------------
  # Helpers — room state
  # ---------------------------------------------------------------------------

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

  defp auth_chain_pdus(events) do
    case auth_chain_ids(events) do
      [] ->
        []

      ids ->
        Repo.all(from(e in Event, where: e.event_id in ^ids))
        |> Enum.map(&EventStore.event_to_pdu/1)
    end
  end

  # Union of the transitive auth chains of `events` (the events themselves
  # excluded unless one is in another's chain): breadth-first, one query per
  # level, each event visited once.
  defp auth_chain_ids(events) do
    events
    |> Enum.flat_map(&(&1.auth_event_ids || []))
    |> expand_auth_chain(MapSet.new())
  end

  defp expand_auth_chain(frontier, seen) do
    case frontier |> Enum.uniq() |> Enum.reject(&(is_nil(&1) or MapSet.member?(seen, &1))) do
      [] ->
        MapSet.to_list(seen)

      new_ids ->
        Repo.all(from(e in Event, where: e.event_id in ^new_ids, select: e.auth_event_ids))
        |> Enum.flat_map(&(&1 || []))
        |> expand_auth_chain(Enum.into(new_ids, seen))
    end
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
  #   403 — origin is ACL-denied (mirror the acl_allowed?/render_error
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
        render_error(conn, :acl_denied)

      not EventStore.room_exists?(room_id) ->
        hierarchy_not_found(conn)

      not server_may_see?(room_id, origin) ->
        hierarchy_not_found(conn)

      true ->
        children = hierarchy_child_events(room_id, suggested_only)
        room = hierarchy_build_entry(room_id, children)

        child_summaries =
          children
          |> Enum.map(& &1["state_key"])
          |> Enum.filter(&EventStore.room_exists?/1)
          |> Enum.filter(&server_may_see?(&1, origin))
          |> Enum.map(fn child_id ->
            hierarchy_build_entry(child_id, hierarchy_child_events(child_id, suggested_only))
          end)

        inaccessible =
          children
          |> Enum.map(& &1["state_key"])
          |> Enum.reject(fn child_id ->
            EventStore.room_exists?(child_id) and server_may_see?(child_id, origin)
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
    state |> allowed_room_ids() |> Enum.any?(&server_joined?(&1, origin))
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
          # Same deterministic ordering as the CS API's child_events/2 —
          # an unordered query left children_state in whatever order
          # Postgres happened to return, which is not reproducible.
          order_by: [asc: e.origin_server_ts, asc: s.state_key],
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

    guest_access = get_in(state, ["m.room.guest_access", "guest_access"]) || "forbidden"

    history_visibility =
      get_in(state, ["m.room.history_visibility", "history_visibility"]) || "shared"

    join_rule = get_in(state, ["m.room.join_rules", "join_rule"]) || "invite"

    allowed_room_ids =
      if join_rule in ["restricted", "knock_restricted"] do
        case allowed_room_ids(state) do
          [] -> nil
          ids -> ids
        end
      end

    %{
      "room_id" => room_id,
      "num_joined_members" => num_joined,
      "world_readable" => history_visibility == "world_readable",
      "guest_can_join" => guest_access == "can_join",
      "join_rule" => join_rule,
      "room_version" => EventStore.get_room_version(room_id, "1"),
      "children_state" => children
    }
    |> maybe_put("name", get_in(state, ["m.room.name", "name"]))
    |> maybe_put("topic", get_in(state, ["m.room.topic", "topic"]))
    |> maybe_put("avatar_url", get_in(state, ["m.room.avatar", "url"]))
    |> maybe_put("canonical_alias", get_in(state, ["m.room.canonical_alias", "alias"]))
    |> maybe_put("room_type", get_in(state, ["m.room.create", "type"]))
    |> maybe_put("encryption", get_in(state, ["m.room.encryption", "algorithm"]))
    |> maybe_put("allowed_room_ids", allowed_room_ids)
  end

  defp allowed_room_ids(state) do
    (get_in(state, ["m.room.join_rules", "allow"]) || [])
    |> Enum.filter(&(&1["type"] == "m.room_membership"))
    |> Enum.map(& &1["room_id"])
    |> Enum.reject(&is_nil/1)
  end
end
