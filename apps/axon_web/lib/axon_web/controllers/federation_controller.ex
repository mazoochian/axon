defmodule AxonWeb.FederationController do
  @moduledoc """
  Inbound Server-Server API handlers.

  All routes are authenticated via X-Matrix header (AxonWeb.Plug.FederationAuth).
  """

  use Phoenix.Controller, formats: [:json]

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, Repo}
  alias AxonCrypto.{EventHash, KeyServer}
  alias AxonRoom.{AuthRules, EventBuilder, RoomProcess, StateResV2}
  alias AxonFederation.{HttpClient, KeyCache}
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
        conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "User ID domain does not match origin"})

      not room_exists?(room_id) ->
        conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found"})

      not join_allowed?(room_id, user_id) ->
        conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Join not allowed"})

      true ->
        version = pick_room_version(room_id, supported_versions)

        # Build partial join event (no hashes/signatures — remote fills those in)
        template = build_join_template(room_id, user_id)

        json(conn, %{
          "room_version" => version,
          "event" => template
        })
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /_matrix/federation/v2/send_join/:room_id/:event_id
  # ---------------------------------------------------------------------------

  def send_join(conn, %{"room_id" => room_id, "event_id" => _event_id} = params) do
    join_event = params |> Map.drop(["room_id", "event_id"])

    with :ok <- validate_join_event(join_event, room_id),
         :ok <- verify_event_signature(join_event),
         {:ok, event_id_actual} <- apply_join_event(room_id, join_event) do
      # Build response: full room state + auth chain
      state_events = EventStore.get_current_state(room_id)
      state_maps = Enum.map(state_events, &EventStore.event_to_map/1)

      auth_chain = build_auth_chain_for_state(state_events)

      json(conn, %{
        "origin" => KeyServer.server_name(),
        "auth_chain" => auth_chain,
        "state" => state_maps,
        "event" => EventStore.event_to_map_by_id(event_id_actual)
      })
    else
      {:error, :invalid_join} ->
        conn |> put_status(400) |> json(%{"errcode" => "M_BAD_JSON", "error" => "Invalid join event"})

      {:error, :bad_signature} ->
        conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Bad event signature"})

      {:error, :auth_failed} ->
        conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Event failed auth check"})

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
        conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "User ID domain does not match origin"})

      not room_exists?(room_id) ->
        conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found"})

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
    leave_event = params |> Map.drop(["room_id", "event_id"])

    with :ok <- verify_event_signature(leave_event),
         {:ok, _} <- apply_leave_event(room_id, leave_event) do
      json(conn, %{})
    else
      {:error, :bad_signature} ->
        conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Bad event signature"})

      _ ->
        conn |> put_status(400) |> json(%{"errcode" => "M_BAD_JSON", "error" => "Invalid leave event"})
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /_matrix/federation/v1/send/:txn_id
  # Receive PDUs from remote server
  # ---------------------------------------------------------------------------

  def send_transaction(conn, %{"txn_id" => txn_id} = params) do
    origin = conn.assigns[:origin_server]
    pdus = params["pdus"] || []

    # Check idempotency
    already_processed =
      Repo.one(
        from t in "federation_inbound_txns",
          where: t.origin == ^origin and t.txn_id == ^txn_id and t.processed == true,
          select: t.id
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

      # Record transaction
      Repo.insert_all("federation_inbound_txns", [
        %{
          origin: origin,
          txn_id: txn_id,
          processed: true,
          inserted_at: DateTime.utc_now(:microsecond)
        }
      ], on_conflict: :nothing)

      json(conn, %{"pdus" => pdu_results})
    end
  end

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
        conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Event not found"})
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/state/:room_id
  # ---------------------------------------------------------------------------

  def get_state(conn, %{"room_id" => room_id} = params) do
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
            from e in "events",
              where: e.event_id in ^ids and e.room_id == ^room_id,
              select: min(e.stream_ordering)
          ) || 0
      end

    events =
      Repo.all(
        from e in "events",
          where: e.room_id == ^room_id and e.stream_ordering < ^from_ordering,
          order_by: [desc: e.stream_ordering],
          limit: ^limit,
          select: e
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
        from e in "events",
          where: e.room_id == ^room_id and e.event_id not in ^MapSet.to_list(known_ids),
          order_by: [desc: e.stream_ordering],
          limit: ^limit
      )

    json(conn, %{
      "events" => Enum.map(events, &EventStore.event_to_map/1)
    })
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/federation/v1/query/directory?room_alias=...
  # ---------------------------------------------------------------------------

  def query_directory(conn, %{"room_alias" => room_alias}) do
    case Repo.one(from a in "room_aliases", where: a.alias == ^room_alias, select: a.room_id) do
      nil ->
        conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room alias not found"})

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
    case Repo.one(from u in "users", where: u.user_id == ^user_id, select: %{display_name: u.display_name, avatar_url: u.avatar_url}) do
      nil ->
        conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "User not found"})

      user ->
        json(conn, %{
          "displayname" => user.display_name,
          "avatar_url" => user.avatar_url
        })
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/key/v2/query (batch key query from remote servers)
  # ---------------------------------------------------------------------------

  def query_keys(conn, _params) do
    info = KeyServer.server_key_info()

    json(conn, %{
      "server_keys" => [%{
        "server_name" => info.server_name,
        "verify_keys" => %{info.key_id => %{"key" => info.public_key_b64}},
        "old_verify_keys" => %{},
        "signatures" => info.signatures,
        "valid_until_ts" => info.valid_until_ts
      }]
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

  defp apply_join_event(room_id, join_event) do
    user_id = join_event["state_key"]
    room_ctx = RoomProcess.get_room_ctx(room_id)
    current_state = room_ctx.current_state

    case AuthRules.check(join_event, current_state) do
      :ok ->
        EventStore.insert_event(join_event, get_room_version(room_id))

      {:error, _reason} ->
        {:error, :auth_failed}
    end
  end

  defp apply_leave_event(room_id, leave_event) do
    current_state = RoomProcess.get_state_map(room_id)

    case AuthRules.check(leave_event, current_state) do
      :ok ->
        EventStore.insert_event(leave_event, get_room_version(room_id))

      {:error, _reason} ->
        {:error, :auth_failed}
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
    version = get_room_version(room_id)
    current_state = RoomProcess.get_state_map(room_id)

    case AuthRules.check(pdu, current_state) do
      :ok ->
        case EventStore.insert_event(pdu, version) do
          {:ok, _} -> :ok
          err -> err
        end

      {:error, reason} ->
        Logger.debug("Soft-fail PDU #{pdu["event_id"]}: #{inspect(reason)}")
        # Soft-fail: store but mark as rejected
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
    Repo.one(from r in "rooms", where: r.room_id == ^room_id, select: r.room_id) != nil
  end

  defp get_room_version(room_id) do
    Repo.one(from r in "rooms", where: r.room_id == ^room_id, select: r.version) || "11"
  end

  defp join_allowed?(room_id, _user_id) do
    # Check join_rules
    join_rule =
      Repo.one(
        from e in "events",
          join: s in "current_room_state",
          on: s.event_id == e.event_id,
          where: s.room_id == ^room_id and s.type == "m.room.join_rules" and s.state_key == "",
          select: fragment("?->>'join_rule'", e.content)
      )

    join_rule in ["public", "knock", nil]
  end

  defp pick_room_version(room_id, supported_versions) do
    version = get_room_version(room_id)
    if version in supported_versions, do: version, else: "11"
  end

  defp build_join_template(room_id, user_id) do
    room_ctx = RoomProcess.get_room_ctx(room_id)

    %{
      "type" => "m.room.member",
      "room_id" => room_id,
      "sender" => user_id,
      "state_key" => user_id,
      "content" => %{"membership" => "join"},
      "origin_server_ts" => System.os_time(:millisecond),
      "origin" => user_id |> String.split(":") |> List.last(),
      "prev_events" => (if room_ctx.last_event_id, do: [room_ctx.last_event_id], else: []),
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
      "prev_events" => (if room_ctx.last_event_id, do: [room_ctx.last_event_id], else: []),
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

    ids ++
      Enum.flat_map(ids, fn id ->
        case EventStore.get_event(id) do
          {:ok, e} -> get_auth_chain_ids(e)
          _ -> []
        end
      end)
    |> Enum.uniq()
  end
end
