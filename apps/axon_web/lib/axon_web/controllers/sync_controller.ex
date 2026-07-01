defmodule AxonWeb.SyncController do
  use Phoenix.Controller, formats: [:json]

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, Repo}
  alias AxonSync.Manager, as: SyncManager

  @default_timeline_limit 100

  # GET /_matrix/client/v3/sync
  def sync(conn, params) do
    user_id = conn.assigns.current_user_id
    since = params["since"]
    timeout = min(String.to_integer(params["timeout"] || "0"), 30_000)

    # nil means initial sync; a string (even "0") means incremental
    is_initial_sync = is_nil(since)
    since_ordering = parse_sync_token(since)

    filter = load_filter(user_id, params["filter"])

    {events_by_room, next_ordering} =
      if timeout > 0 do
        {:ok, by_room} = SyncManager.wait_for_events(user_id, since_ordering, timeout)
        max_ord = get_max_ordering(by_room, since_ordering)
        {by_room, max_ord}
      else
        by_room = EventStore.get_user_events_since(user_id, since_ordering)
        max_ord = get_max_ordering(by_room, since_ordering)
        {by_room, max_ord}
      end

    # For initial sync with no events yet, anchor at current DB max
    next_ordering =
      if is_initial_sync and next_ordering == since_ordering do
        EventStore.current_max_stream_ordering()
      else
        next_ordering
      end

    next_batch = Integer.to_string(next_ordering)

    rooms_response = build_rooms_response(user_id, events_by_room, is_initial_sync, since_ordering, filter)

    json(conn, %{
      "next_batch" => next_batch,
      "rooms" => rooms_response,
      "presence" => %{"events" => []},
      "account_data" => %{"events" => []}
    })
  end

  # ---------------------------------------------------------------------------
  # Filter loading
  # ---------------------------------------------------------------------------

  defp load_filter(_user_id, nil), do: %{}

  defp load_filter(user_id, filter_param) do
    # filter_param can be an ID (stored) or inline JSON
    case Jason.decode(filter_param) do
      {:ok, inline} ->
        inline

      {:error, _} ->
        # treat as filter_id
        case Repo.one(
               from f in "user_filters",
                 where: f.filter_id == ^filter_param and f.user_id == ^user_id,
                 select: f.filter
             ) do
          nil -> %{}
          json_str -> Jason.decode!(json_str)
        end
    end
  end

  defp filter_timeline_types(filter), do: get_in(filter, ["room", "timeline", "types"])
  defp filter_state_types(filter), do: get_in(filter, ["room", "state", "types"])

  defp filter_timeline_limit(filter) do
    get_in(filter, ["room", "timeline", "limit"]) || @default_timeline_limit
  end

  defp apply_type_filter(events, nil), do: events
  defp apply_type_filter(events, types), do: Enum.filter(events, &(&1["type"] in types))

  # ---------------------------------------------------------------------------
  # Sync response builder
  # ---------------------------------------------------------------------------

  defp build_rooms_response(user_id, events_by_room, is_initial_sync, since_ordering, filter) do
    joined_rooms = EventStore.get_joined_rooms(user_id)
    invited_rooms = EventStore.get_invited_rooms(user_id)
    tl_limit = filter_timeline_limit(filter)
    tl_types = filter_timeline_types(filter)
    state_types = filter_state_types(filter)

    join_response =
      joined_rooms
      |> Enum.reduce(%{}, fn room_id, acc ->
        room_events = Map.get(events_by_room, room_id, [])
        has_new_events = room_events != []

        if not is_initial_sync and not has_new_events do
          acc
        else
          room_data = build_room_data(
            room_id, user_id, room_events,
            is_initial_sync, since_ordering,
            tl_limit, tl_types, state_types
          )
          Map.put(acc, room_id, room_data)
        end
      end)

    invite_response =
      Enum.into(invited_rooms, %{}, fn room_id ->
        invite_state = build_invite_state(room_id, user_id)
        {room_id, %{"invite_state" => %{"events" => invite_state}}}
      end)

    left_rooms = EventStore.get_left_rooms_since(user_id, since_ordering, exclude_forgotten: is_initial_sync)
    leave_response =
      Enum.into(left_rooms, %{}, fn room_id ->
        leave_events = Map.get(events_by_room, room_id, [])
        {room_id, %{
          "timeline" => %{"events" => Enum.map(leave_events, &EventStore.event_to_map/1), "limited" => false},
          "state" => %{"events" => []}
        }}
      end)

    %{
      "join" => join_response,
      "invite" => invite_response,
      "leave" => leave_response
    }
  end

  defp build_room_data(room_id, user_id, room_events, is_initial_sync, since_ordering, tl_limit, tl_types, state_types) do
    # Did this user newly join this room in this sync window?
    newly_joined =
      not is_initial_sync and
        Enum.any?(room_events, fn e ->
          e.type == "m.room.member" and
            e.state_key == user_id and
            get_in(e.content, ["membership"]) == "join"
        end)

    {state_events, timeline_events, limited, prev_batch} =
      cond do
        is_initial_sync ->
          build_initial_room_data(room_id, room_events, tl_limit, since_ordering)

        newly_joined ->
          build_newly_joined_room_data(room_id, user_id, room_events, tl_limit, tl_types, since_ordering)

        true ->
          build_incremental_room_data(room_events, tl_limit, since_ordering)
      end

    # Apply type filter to state section
    filtered_state = apply_type_filter(state_events, state_types)
    # Apply type filter to timeline
    filtered_timeline = apply_type_filter(timeline_events, tl_types)

    ephemeral = build_ephemeral(room_id)
    room_account_data = build_room_account_data(room_id, user_id)

    %{
      "timeline" => %{
        "events" => filtered_timeline,
        "limited" => limited,
        "prev_batch" => prev_batch
      },
      "state" => %{"events" => filtered_state},
      "account_data" => %{"events" => room_account_data},
      "ephemeral" => %{"events" => ephemeral},
      "summary" => %{}
    }
  end

  # Initial sync: state = full current state, timeline = most recent events
  defp build_initial_room_data(room_id, room_events, tl_limit, _since_ordering) do
    full_state = EventStore.get_current_state(room_id) |> Enum.map(&EventStore.event_to_map/1)
    {limited, tl_events} =
      if length(room_events) > tl_limit do
        {true, Enum.take(room_events, -tl_limit)}
      else
        {false, room_events}
      end
    prev = if limited and tl_events != [] do
      Integer.to_string(hd(tl_events).stream_ordering - 1)
    else
      "0"
    end
    {full_state, Enum.map(tl_events, &EventStore.event_to_map/1), limited, prev}
  end

  # Newly joined room: state = full room state, timeline = events after join (limited=true for history)
  defp build_newly_joined_room_data(room_id, user_id, room_events, tl_limit, _tl_types, since_ordering) do
    full_state = EventStore.get_current_state(room_id) |> Enum.map(&EventStore.event_to_map/1)

    # Find the join event ordering
    join_event = Enum.find(room_events, fn e ->
      e.type == "m.room.member" and
        e.state_key == user_id and
        get_in(e.content, ["membership"]) == "join"
    end)

    # Events after the join (exclude state events from timeline; the join itself goes in state)
    events_after_join =
      if join_event do
        room_events
        |> Enum.filter(&(&1.stream_ordering > join_event.stream_ordering))
      else
        room_events
      end

    # Also include non-state events between since_ordering and join (for context)
    # but cap at tl_limit
    {limited, tl_events} =
      if length(events_after_join) > tl_limit do
        {true, Enum.take(events_after_join, -tl_limit)}
      else
        # limited=true because there's history before the join
        {true, events_after_join}
      end

    _ = since_ordering  # suppress unused warning

    prev = if tl_events != [] do
      Integer.to_string(hd(tl_events).stream_ordering - 1)
    else
      if join_event, do: Integer.to_string(join_event.stream_ordering), else: "0"
    end

    {full_state, Enum.map(tl_events, &EventStore.event_to_map/1), limited, prev}
  end

  # Incremental sync: state = state events before timeline window, timeline = recent events
  defp build_incremental_room_data(room_events, tl_limit, since_ordering) do
    {limited, tl_events} =
      if length(room_events) > tl_limit do
        {true, Enum.take(room_events, -tl_limit)}
      else
        {false, room_events}
      end

    # State events between since and start of timeline window go into state section
    state_events =
      if limited do
        cutoff = hd(tl_events).stream_ordering
        room_events
        |> Enum.filter(&(&1.stream_ordering < cutoff and &1.state_key != nil))
        |> Enum.map(&EventStore.event_to_map/1)
      else
        []
      end

    _ = since_ordering

    prev = if limited and tl_events != [] do
      Integer.to_string(hd(tl_events).stream_ordering - 1)
    else
      "0"
    end

    {state_events, Enum.map(tl_events, &EventStore.event_to_map/1), limited, prev}
  end

  # ---------------------------------------------------------------------------
  # Invite state builder
  # ---------------------------------------------------------------------------

  @invite_state_types ~w(m.room.join_rules m.room.canonical_alias m.room.avatar m.room.name m.room.create m.room.encryption)

  defp build_invite_state(room_id, user_id) do
    current_state = EventStore.get_current_state(room_id)

    stripped =
      current_state
      |> Enum.filter(fn e -> e.type in @invite_state_types end)
      |> Enum.map(&stripped_event/1)

    case EventStore.get_state_event(room_id, "m.room.member", user_id) do
      {:ok, invite_event} -> stripped ++ [stripped_event(invite_event)]
      _ -> stripped
    end
  end

  defp stripped_event(event) do
    %{
      "type" => event.type,
      "state_key" => event.state_key,
      "sender" => event.sender,
      "content" => event.content || %{}
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp parse_sync_token(nil), do: 0
  defp parse_sync_token(since) do
    case Integer.parse(since) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp build_room_account_data(room_id, user_id) do
    Repo.all(
      from r in "room_account_data",
        where: r.room_id == ^room_id and r.user_id == ^user_id,
        select: %{type: r.type, content: r.content}
    )
    |> Enum.map(fn r -> %{"type" => r.type, "content" => r.content} end)
  end

  defp build_ephemeral(room_id) do
    receipts =
      Repo.all(
        from r in "receipts",
          where: r.room_id == ^room_id and r.receipt_type in ["m.read", "m.read.private"],
          select: %{user_id: r.user_id, receipt_type: r.receipt_type, event_id: r.event_id, ts: r.ts}
      )

    if receipts == [] do
      []
    else
      content =
        Enum.reduce(receipts, %{}, fn r, acc ->
          user_entry = %{"ts" => r.ts}
          type_map = Map.get(acc, r.event_id, %{})
          users_map = Map.get(type_map, r.receipt_type, %{})
          updated_type_map = Map.put(type_map, r.receipt_type, Map.put(users_map, r.user_id, user_entry))
          Map.put(acc, r.event_id, updated_type_map)
        end)

      [%{"type" => "m.receipt", "content" => content}]
    end
  end

  defp get_max_ordering(events_by_room, fallback) do
    events_by_room
    |> Map.values()
    |> List.flatten()
    |> Enum.reduce(fallback, fn e, acc ->
      max(acc, e.stream_ordering)
    end)
  end
end
