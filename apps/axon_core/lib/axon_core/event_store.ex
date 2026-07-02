defmodule AxonCore.EventStore do
  @moduledoc """
  All database operations for the Matrix event store.

  The events table is append-only. State is derived from events and
  maintained in current_room_state for fast lookup.
  """

  import Ecto.Query
  alias AxonCore.Repo
  alias AxonCore.Schema.{Event, Room, RoomMembership}

  # ---------------------------------------------------------------------------
  # Event insertion (the critical path)
  # ---------------------------------------------------------------------------

  @doc """
  Atomically inserts an event and updates derived state tables.

  The event map should be a fully-signed, finalized Matrix event map
  (with event_id, signatures, hashes set).
  """
  def insert_event(event_map, room_version) do
    params = Event.from_wire(event_map, room_version)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:event_raw, Event.changeset(%Event{}, params),
      on_conflict: :nothing,
      conflict_target: :event_id
    )
    |> Ecto.Multi.run(:event, fn repo, %{event_raw: _raw} ->
      # Reload to get DB-assigned stream_ordering (BIGSERIAL).
      # Also handles the on_conflict: :nothing case — we still need the persisted row.
      case repo.get_by(Event, event_id: params.event_id) do
        nil -> {:error, :event_not_found}
        event -> {:ok, event}
      end
    end)
    |> Ecto.Multi.run(:state, fn repo, %{event: event} ->
      update_current_state(repo, event)
    end)
    |> Ecto.Multi.run(:membership, fn repo, %{event: event} ->
      update_membership(repo, event)
    end)
    |> Ecto.Multi.run(:auth_edges, fn repo, %{event: event} ->
      insert_auth_edges(repo, event)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{event: event}} -> {:ok, event}
      {:error, :event_raw, changeset, _} -> {:error, changeset}
      {:error, step, reason, _} -> {:error, {step, reason}}
    end
  end

  defp update_current_state(_repo, %Event{state_key: nil}), do: {:ok, nil}

  defp update_current_state(repo, event) do
    repo.insert_all(
      "current_room_state",
      [
        %{
          room_id: event.room_id,
          type: event.type,
          state_key: event.state_key,
          event_id: event.event_id
        }
      ],
      on_conflict: {:replace, [:event_id]},
      conflict_target: [:room_id, :type, :state_key]
    )

    {:ok, nil}
  end

  defp update_membership(_repo, %Event{type: type}) when type != "m.room.member", do: {:ok, nil}

  defp update_membership(repo, event) do
    membership = get_in(event.content, ["membership"])
    target_user_id = event.state_key

    if membership && target_user_id do
      repo.insert_all(
        "room_memberships",
        [
          %{
            room_id: event.room_id,
            user_id: target_user_id,
            membership: membership,
            event_id: event.event_id,
            sender: event.sender,
            display_name: get_in(event.content, ["displayname"]),
            avatar_url: get_in(event.content, ["avatar_url"]),
            forgotten: false,
            inserted_at: DateTime.utc_now(:microsecond),
            updated_at: DateTime.utc_now(:microsecond)
          }
        ],
        on_conflict: {:replace, [:membership, :event_id, :sender, :display_name, :avatar_url, :forgotten, :updated_at]},
        conflict_target: [:room_id, :user_id]
      )

      {:ok, nil}
    else
      {:ok, nil}
    end
  end

  defp insert_auth_edges(_repo, %Event{auth_event_ids: []}), do: {:ok, nil}

  defp insert_auth_edges(repo, event) do
    rows =
      Enum.map(event.auth_event_ids, fn auth_id ->
        %{event_id: event.event_id, auth_event_id: auth_id}
      end)

    repo.insert_all("event_auth_edges", rows, on_conflict: :nothing)
    {:ok, nil}
  end

  # ---------------------------------------------------------------------------
  # Room creation
  # ---------------------------------------------------------------------------

  def insert_room(room_id, creator, version \\ "11", is_public \\ false) do
    %Room{}
    |> Room.changeset(%{room_id: room_id, creator: creator, version: version, is_public: is_public})
    |> Repo.insert()
  end

  def get_room(room_id) do
    case Repo.get(Room, room_id) do
      nil -> {:error, :not_found}
      room -> {:ok, room}
    end
  end

  # ---------------------------------------------------------------------------
  # Event queries
  # ---------------------------------------------------------------------------

  def get_event(event_id) do
    case Repo.get_by(Event, event_id: event_id) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  @doc "Returns events in a room with stream_ordering > since, in order."
  def get_events_since(room_id, since_ordering, limit \\ 100) do
    Repo.all(
      from e in Event,
        where:
          e.room_id == ^room_id and
            e.stream_ordering > ^since_ordering and
            not e.rejected and
            not e.soft_failed,
        order_by: [asc: e.stream_ordering],
        limit: ^limit
    )
  end

  @doc "Paginate room history (for GET /rooms/:id/messages)."
  def get_messages(room_id, from_ordering, dir, limit \\ 10) do
    base =
      from e in Event,
        where: e.room_id == ^room_id and not e.rejected and not e.soft_failed

    query =
      case dir do
        "b" ->
          from e in base,
            where: e.stream_ordering < ^from_ordering,
            order_by: [desc: e.stream_ordering],
            limit: ^limit

        _ ->
          from e in base,
            where: e.stream_ordering > ^from_ordering,
            order_by: [asc: e.stream_ordering],
            limit: ^limit
      end

    Repo.all(query)
  end

  @doc "Returns the current max stream_ordering across all events."
  def current_max_stream_ordering do
    Repo.one(from e in Event, select: max(e.stream_ordering)) || 0
  end

  @doc "Returns the max stream_ordering in a specific room."
  def room_max_stream_ordering(room_id) do
    Repo.one(
      from e in Event,
        where: e.room_id == ^room_id,
        select: max(e.stream_ordering)
    ) || 0
  end

  # ---------------------------------------------------------------------------
  # Room state queries
  # ---------------------------------------------------------------------------

  @doc "Returns all current state events for a room as a list of event maps."
  def get_current_state(room_id) do
    Repo.all(
      from e in Event,
        join: s in "current_room_state",
        on: s.event_id == e.event_id and s.room_id == ^room_id,
        where: not e.rejected,
        select: e
    )
  end

  @doc "Returns the current state event for {room_id, type, state_key}."
  def get_state_event(room_id, type, state_key) do
    result =
      Repo.one(
        from e in Event,
          join: s in "current_room_state",
          on:
            s.event_id == e.event_id and
              s.room_id == ^room_id and
              s.type == ^type and
              s.state_key == ^state_key,
          where: not e.rejected,
          select: e
      )

    case result do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  @doc "Returns current state as a map of {type, state_key} => event_map for use in auth rules."
  def get_current_state_map(room_id) do
    room_id
    |> get_current_state()
    |> Enum.reduce(%{}, fn event, acc ->
      Map.put(acc, {event.type, event.state_key}, event_to_map(event))
    end)
  end

  # ---------------------------------------------------------------------------
  # Membership queries
  # ---------------------------------------------------------------------------

  def get_joined_rooms(user_id) do
    Repo.all(
      from m in RoomMembership,
        where: m.user_id == ^user_id and m.membership == "join" and not m.forgotten,
        select: m.room_id
    )
  end

  def get_invited_rooms(user_id) do
    Repo.all(
      from m in RoomMembership,
        where: m.user_id == ^user_id and m.membership == "invite" and not m.forgotten,
        select: m.room_id
    )
  end

  def get_left_rooms_since(user_id, since_ordering, opts \\ []) do
    exclude_forgotten = Keyword.get(opts, :exclude_forgotten, false)

    q =
      from m in RoomMembership,
        join: e in Event,
        on: e.event_id == m.event_id,
        where:
          m.user_id == ^user_id and
          m.membership in ["leave", "ban"] and
          e.stream_ordering > ^since_ordering,
        select: m.room_id

    q = if exclude_forgotten, do: from(m in q, where: not m.forgotten), else: q
    Repo.all(q)
  end

  def get_room_members(room_id, memberships \\ ["join"]) do
    Repo.all(
      from m in RoomMembership,
        where: m.room_id == ^room_id and m.membership in ^memberships,
        select: m
    )
  end

  def get_membership(room_id, user_id) do
    case Repo.get_by(RoomMembership, room_id: room_id, user_id: user_id) do
      nil -> {:ok, nil}
      m -> {:ok, m.membership}
    end
  end

  # ---------------------------------------------------------------------------
  # Snapshots
  # ---------------------------------------------------------------------------

  def latest_snapshot(room_id) do
    Repo.one(
      from s in "room_state_snapshots",
        where: s.room_id == ^room_id,
        order_by: [desc: s.after_stream_ordering],
        limit: 1,
        select: %{
          after_stream_ordering: s.after_stream_ordering,
          state_map: s.state_map
        }
    )
  end

  def create_snapshot(room_id, after_stream_ordering, state_map) do
    # state_map is a map with string keys "{type}\0{state_key}" => event_id
    Repo.insert_all("room_state_snapshots", [
      %{
        room_id: room_id,
        after_stream_ordering: after_stream_ordering,
        state_map: state_map,
        inserted_at: DateTime.utc_now(:microsecond)
      }
    ])

    :ok
  end

  # ---------------------------------------------------------------------------
  # Sync helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns all events for rooms the user is in, since the given stream_ordering.
  Groups results by room_id.
  """
  def get_user_events_since(user_id, since_ordering) do
    joined_rooms = get_joined_rooms(user_id)
    left_rooms = get_left_rooms_since(user_id, since_ordering)
    all_rooms = Enum.uniq(joined_rooms ++ left_rooms)

    if all_rooms == [] do
      %{}
    else
      events =
        Repo.all(
          from e in Event,
            where:
              e.room_id in ^all_rooms and
                e.stream_ordering > ^since_ordering and
                not e.rejected and
                not e.soft_failed,
            order_by: [asc: e.stream_ordering]
        )

      Enum.group_by(events, & &1.room_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc "Converts an Event schema struct to a wire-format map."
  def event_to_map(%Event{} = e) do
    base = %{
      "event_id" => e.event_id,
      "room_id" => e.room_id,
      "sender" => e.sender,
      "type" => e.type,
      "content" => e.content || %{},
      "origin_server_ts" => e.origin_server_ts,
      "depth" => e.depth,
      "auth_events" => e.auth_event_ids,
      "prev_events" => e.prev_event_ids,
      "signatures" => e.signatures,
      "hashes" => e.hashes
    }

    base
    |> maybe_put("state_key", e.state_key)
    |> maybe_put("unsigned", e.unsigned)
  end

  def event_to_map(m) when is_map(m), do: m

  @doc "Returns true if the room exists locally."
  def room_exists?(room_id) do
    import Ecto.Query
    Repo.one(from r in "rooms", where: r.room_id == ^room_id, select: r.room_id) != nil
  end

  @doc "Fetch event by ID and convert to wire-format map."
  def event_to_map_by_id(event_id) do
    case get_event(event_id) do
      {:ok, e} -> event_to_map(e)
      _ -> nil
    end
  end

  @doc "Fetch an event map by ID for use in state resolution auth chain traversal."
  def get_event_map(event_id) do
    case get_event(event_id) do
      {:ok, e} -> event_to_map(e)
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
