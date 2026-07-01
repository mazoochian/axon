defmodule AxonWeb.EventController do
  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, Repo}
  alias AxonRoom.RoomProcess

  # PUT /_matrix/client/v3/rooms/:room_id/send/:event_type/:txn_id
  def send_event(conn, %{"room_id" => room_id, "event_type" => event_type, "txn_id" => txn_id} = params) do
    user_id = conn.assigns.current_user_id
    device_id = conn.assigns.current_device_id
    content = Map.drop(params, ~w(room_id event_type txn_id))

    # Idempotency check
    case check_txn_idempotency(user_id, device_id, txn_id) do
      {:already_sent, event_id} ->
        json(conn, %{"event_id" => event_id})

      :new ->
        with {:ok, event_id} <- RoomProcess.send_event(room_id, user_id, event_type, content) do
          record_txn(user_id, device_id, txn_id, event_id)
          json(conn, %{"event_id" => event_id})
        end
    end
  end

  # PUT /_matrix/client/v3/rooms/:room_id/state/:event_type
  # PUT /_matrix/client/v3/rooms/:room_id/state/:event_type/:state_key
  def send_state_event(conn, %{"room_id" => room_id, "event_type" => event_type} = params) do
    user_id = conn.assigns.current_user_id
    state_key = params["state_key"] || ""
    content = Map.drop(params, ~w(room_id event_type state_key))

    with :ok <- validate_state_event(event_type, content, room_id),
         {:ok, event_id} <-
           RoomProcess.send_event(room_id, user_id, event_type, content, state_key: state_key) do
      json(conn, %{"event_id" => event_id})
    end
  end

  defp validate_state_event("m.room.canonical_alias", content, room_id) do
    alias_val = content["alias"]
    alt_aliases = content["alt_aliases"] || []

    all_aliases = (if alias_val, do: [alias_val], else: []) ++ alt_aliases

    # First validate format: must start with # and contain :
    invalid_format = Enum.find(all_aliases, fn a ->
      not (is_binary(a) and String.starts_with?(a, "#") and String.contains?(a, ":"))
    end)

    if invalid_format do
      {:error, {:invalid_alias_format, invalid_format}}
    else
      bad =
        Enum.find(all_aliases, fn a ->
          case Repo.one(from a2 in "room_aliases", where: a2.alias == ^a, select: a2.room_id) do
            ^room_id -> false
            _ -> true
          end
        end)

      if bad do
        {:error, {:bad_canonical_alias, bad}}
      else
        :ok
      end
    end
  end

  defp validate_state_event(_type, _content, _room_id), do: :ok

  # GET /_matrix/client/v3/rooms/:room_id/state
  def get_state(conn, %{"room_id" => room_id}) do
    case RoomProcess.get_state(room_id) do
      {:ok, events} ->
        json(conn, events)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # GET /_matrix/client/v3/rooms/:room_id/state/:event_type/:state_key
  def get_state_event(conn, %{"room_id" => room_id, "event_type" => event_type} = params) do
    state_key = params["state_key"] || ""
    format = params["format"]

    case RoomProcess.get_state_event(room_id, event_type, state_key) do
      nil ->
        {:error, :not_found}

      event ->
        if format == "event" do
          json(conn, event)
        else
          json(conn, event["content"] || %{})
        end
    end
  end

  # GET /_matrix/client/v3/rooms/:room_id/event/:event_id
  def get_event(conn, %{"room_id" => room_id, "event_id" => event_id}) do
    with {:ok, event} <- EventStore.get_event(event_id) do
      if event.room_id != room_id do
        {:error, :not_found}
      else
        json(conn, EventStore.event_to_map(event))
      end
    end
  end

  # GET /_matrix/client/v3/rooms/:room_id/messages
  def get_messages(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id

    # Check if user has access to this room (not forgotten, was a member)
    membership =
      Repo.one(
        from m in "room_memberships",
          where: m.room_id == ^room_id and m.user_id == ^user_id,
          select: %{membership: m.membership, forgotten: m.forgotten}
      )

    if membership != nil and membership.forgotten do
      conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Room is forgotten"})
    else

    from_token = params["from"]
    dir = params["dir"] || "b"
    limit = String.to_integer(params["limit"] || "10")

    from_ordering = parse_token(from_token) || EventStore.room_max_stream_ordering(room_id)

    events = EventStore.get_messages(room_id, from_ordering, dir, limit)

    start_token = if from_token, do: from_token, else: Integer.to_string(from_ordering)
    end_ordering =
      if events == [],
        do: from_ordering,
        else: (if dir == "b", do: hd(events).stream_ordering, else: List.last(events).stream_ordering)

    json(conn, %{
      "start" => start_token,
      "end" => Integer.to_string(end_ordering),
      "chunk" => Enum.map(events, &EventStore.event_to_map/1),
      "state" => []
    })
    end
  end

  # PUT /_matrix/client/v3/rooms/:room_id/redact/:event_id/:txn_id
  def redact(conn, %{"room_id" => room_id, "event_id" => redacts_event_id, "txn_id" => txn_id} = params) do
    user_id = conn.assigns.current_user_id
    device_id = conn.assigns.current_device_id
    reason = params["reason"]

    content = %{"redacts" => redacts_event_id}
    content = if reason, do: Map.put(content, "reason", reason), else: content

    case check_txn_idempotency(user_id, device_id, txn_id) do
      {:already_sent, event_id} ->
        json(conn, %{"event_id" => event_id})

      :new ->
        with {:ok, event_id} <- RoomProcess.send_event(room_id, user_id, "m.room.redaction", content) do
          record_txn(user_id, device_id, txn_id, event_id)
          json(conn, %{"event_id" => event_id})
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp check_txn_idempotency(user_id, device_id, txn_id) do
    import Ecto.Query

    case Repo.one(
           from t in "client_txns",
             where:
               t.user_id == ^user_id and
                 t.device_id == ^device_id and
                 t.txn_id == ^txn_id,
             select: t.event_id
         ) do
      nil -> :new
      event_id -> {:already_sent, event_id}
    end
  end

  defp record_txn(user_id, device_id, txn_id, event_id) do
    Repo.insert_all("client_txns", [
      %{
        user_id: user_id,
        device_id: device_id,
        txn_id: txn_id,
        event_id: event_id,
        inserted_at: DateTime.utc_now(:microsecond)
      }
    ], on_conflict: :nothing)
  end

  defp parse_token(nil), do: nil
  defp parse_token(t) do
    case Integer.parse(t) do
      {n, _} -> n
      :error -> nil
    end
  end
end
