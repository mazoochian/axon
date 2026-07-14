defmodule AxonWeb.SyncController do
  use Phoenix.Controller, formats: [:json]

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, Repo}
  alias AxonSync.Manager, as: SyncManager
  alias AxonWeb.SyncHelpers

  @default_timeline_limit 100

  # GET /_matrix/client/v3/sync
  def sync(conn, params) do
    user_id = conn.assigns.current_user_id
    device_id = conn.assigns.current_device_id
    since = params["since"]
    timeout = min(String.to_integer(params["timeout"] || "0"), 30_000)

    # nil means initial sync; a string (even "0") means incremental
    is_initial_sync = is_nil(since)

    # next_batch token format:
    # "${room_ordering}_${dl_cursor}_${ad_cursor}_${pr_cursor}_${left_cursor}_${eph_cursor}"
    # dl_cursor tracks device_list_updates.id; ad_cursor tracks account_data_stream.id;
    # pr_cursor tracks AxonSync.Presence's version counter; left_cursor tracks
    # device_list_partings.id; eph_cursor tracks ephemeral_updates.id (typing/receipts).
    {since_ordering, dl_since, ad_since, pr_since, left_since, eph_since} =
      SyncHelpers.parse_token(since)

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

    # Advance cursors to current maxes
    dl_next = SyncHelpers.current_dl_max_id()
    ad_next = SyncHelpers.current_ad_max_id()
    pr_next = AxonSync.Presence.current_version()
    left_next = SyncHelpers.current_left_max_id()
    eph_next = SyncHelpers.current_eph_max_id()

    next_batch =
      SyncHelpers.build_token(next_ordering, dl_next, ad_next, pr_next, left_next, eph_next)

    rooms_response =
      build_rooms_response(
        user_id,
        events_by_room,
        is_initial_sync,
        since_ordering,
        eph_since,
        filter
      )

    global_account_data = SyncHelpers.get_global_account_data(user_id, is_initial_sync, ad_since)
    presence_events = SyncHelpers.get_presence_events(user_id, is_initial_sync, pr_since)

    # E2EE sync additions
    {to_device_events, _max_tdm_id} = SyncHelpers.drain_to_device_messages(user_id, device_id)
    otk_counts = SyncHelpers.get_otk_counts(user_id, device_id)
    unused_fallback_types = SyncHelpers.get_unused_fallback_key_types(user_id, device_id)

    device_lists =
      if is_initial_sync do
        %{"changed" => [], "left" => []}
      else
        SyncHelpers.get_device_list_changes(user_id, dl_since, left_since)
      end

    resp = %{
      "next_batch" => next_batch,
      "rooms" => rooms_response,
      "presence" => %{"events" => presence_events},
      "account_data" => %{"events" => global_account_data},
      "to_device" => %{"events" => to_device_events},
      "device_one_time_keys_count" => otk_counts,
      "device_unused_fallback_key_types" => unused_fallback_types,
      "device_lists" => device_lists
    }

    json(conn, resp)
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
               from(f in "user_filters",
                 where: f.filter_id == ^filter_param and f.user_id == ^user_id,
                 select: f.filter
               )
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

  defp build_rooms_response(
         user_id,
         events_by_room,
         is_initial_sync,
         since_ordering,
         eph_since,
         filter
       ) do
    joined_rooms = EventStore.get_joined_rooms(user_id)
    invited_rooms = EventStore.get_invited_rooms(user_id)
    tl_limit = filter_timeline_limit(filter)
    tl_types = filter_timeline_types(filter)
    state_types = filter_state_types(filter)

    join_response =
      joined_rooms
      |> Enum.reduce(%{}, fn room_id, acc ->
        room_events = Map.get(events_by_room, room_id, [])

        has_new_events =
          room_events != [] or SyncHelpers.has_ephemeral_change?(room_id, eph_since)

        if not is_initial_sync and not has_new_events do
          acc
        else
          room_data =
            build_room_data(
              room_id,
              user_id,
              room_events,
              is_initial_sync,
              since_ordering,
              tl_limit,
              tl_types,
              state_types
            )

          Map.put(acc, room_id, room_data)
        end
      end)

    # Get ignored users for this sync user
    ignored_users = get_ignored_users(user_id)

    invite_response =
      invited_rooms
      |> Enum.reject(fn room_id -> invite_from_ignored?(room_id, user_id, ignored_users) end)
      |> Enum.into(%{}, fn room_id ->
        invite_state = build_invite_state(room_id, user_id)
        {room_id, %{"invite_state" => %{"events" => invite_state}}}
      end)

    left_rooms =
      EventStore.get_left_rooms_since(user_id, since_ordering, exclude_forgotten: is_initial_sync)

    leave_response =
      Enum.into(left_rooms, %{}, fn room_id ->
        leave_events = Map.get(events_by_room, room_id, [])

        {room_id,
         %{
           "timeline" => %{
             "events" => Enum.map(leave_events, &EventStore.event_to_map/1),
             "limited" => false
           },
           "state" => %{"events" => []}
         }}
      end)

    knocked_rooms = EventStore.get_knocked_rooms(user_id)

    knock_response =
      Enum.into(knocked_rooms, %{}, fn room_id ->
        {room_id,
         %{"knock_state" => %{"events" => EventStore.get_knock_preview_state(room_id, user_id)}}}
      end)

    %{
      "join" => join_response,
      "invite" => invite_response,
      "knock" => knock_response,
      "leave" => leave_response
    }
  end

  defp build_room_data(
         room_id,
         user_id,
         room_events,
         is_initial_sync,
         since_ordering,
         tl_limit,
         tl_types,
         state_types
       ) do
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
          build_newly_joined_room_data(
            room_id,
            user_id,
            room_events,
            tl_limit,
            tl_types,
            since_ordering
          )

        true ->
          build_incremental_room_data(room_events, tl_limit, since_ordering)
      end

    # Apply type filter to state section
    filtered_state = apply_type_filter(state_events, state_types)
    # Apply type filter to timeline
    filtered_timeline = apply_type_filter(timeline_events, tl_types)

    ephemeral =
      SyncHelpers.build_receipt_events(room_id) ++ SyncHelpers.build_typing_event(room_id)

    room_account_data = SyncHelpers.build_room_account_data(room_id, user_id)

    # Add unsigned.membership to timeline events (MSC4115)
    timeline_with_membership = add_membership_to_timeline(filtered_timeline, room_id, user_id)
    # Bundle reaction/thread aggregations (unsigned.m.relations)
    timeline_with_relations =
      EventStore.bundle_relations(room_id, timeline_with_membership, user_id: user_id)

    %{
      "timeline" => %{
        "events" => timeline_with_relations,
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

    prev =
      if limited and tl_events != [] do
        Integer.to_string(hd(tl_events).stream_ordering - 1)
      else
        "0"
      end

    {full_state, Enum.map(tl_events, &EventStore.event_to_map/1), limited, prev}
  end

  # Newly joined room: state = full room state, timeline = events after join (limited=true for history)
  defp build_newly_joined_room_data(
         room_id,
         user_id,
         room_events,
         tl_limit,
         _tl_types,
         since_ordering
       ) do
    full_state = EventStore.get_current_state(room_id) |> Enum.map(&EventStore.event_to_map/1)

    # Find the join event ordering
    join_event =
      Enum.find(room_events, fn e ->
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

    # suppress unused warning
    _ = since_ordering

    prev =
      if tl_events != [] do
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

    prev =
      if limited and tl_events != [] do
        Integer.to_string(hd(tl_events).stream_ordering - 1)
      else
        "0"
      end

    {state_events, Enum.map(tl_events, &EventStore.event_to_map/1), limited, prev}
  end

  # ---------------------------------------------------------------------------
  # Invite state builder
  # ---------------------------------------------------------------------------

  defp build_invite_state(room_id, user_id) do
    stripped = EventStore.stripped_state_events(room_id)

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

  defp add_membership_to_timeline([], _room_id, _user_id), do: []

  defp add_membership_to_timeline(events, room_id, user_id) do
    # Batch fetch stream_ordering for all events in the timeline
    event_ids = Enum.map(events, & &1["event_id"]) |> Enum.reject(&is_nil/1)

    ordering_map =
      if event_ids == [] do
        %{}
      else
        Repo.all(
          from(e in "events",
            where: e.event_id in ^event_ids,
            select: {e.event_id, e.stream_ordering}
          )
        )
        |> Map.new()
      end

    # Get all membership changes for this user in this room, ordered by stream_ordering
    membership_changes =
      Repo.all(
        from(e in "events",
          where:
            e.room_id == ^room_id and
              e.type == "m.room.member" and
              e.state_key == ^user_id,
          order_by: [asc: e.stream_ordering],
          select: %{
            stream_ordering: e.stream_ordering,
            membership: fragment("?->>'membership'", e.content)
          }
        )
      )

    Enum.map(events, fn event ->
      ordering = ordering_map[event["event_id"]]
      membership = membership_at_ordering(ordering, membership_changes)
      unsigned = Map.merge(event["unsigned"] || %{}, %{"membership" => membership})
      Map.put(event, "unsigned", unsigned)
    end)
  end

  defp membership_at_ordering(nil, _changes), do: "leave"

  defp membership_at_ordering(ordering, changes) do
    applicable = Enum.filter(changes, &(&1.stream_ordering <= ordering))

    case List.last(applicable) do
      nil -> "leave"
      %{membership: m} when m in ["join", "invite", "ban"] -> m
      _ -> "leave"
    end
  end

  defp get_ignored_users(user_id) do
    case Repo.one(
           from(a in "account_data",
             where: a.user_id == ^user_id and a.type == "m.ignored_user_list",
             select: a.content
           )
         ) do
      nil ->
        MapSet.new()

      content ->
        ignored = get_in(content, ["ignored_users"]) || %{}
        MapSet.new(Map.keys(ignored))
    end
  end

  defp invite_from_ignored?(room_id, _user_id, ignored_users) do
    if MapSet.size(ignored_users) == 0 do
      false
    else
      sender =
        Repo.one(
          from(e in "events",
            where:
              e.room_id == ^room_id and
                e.type == "m.room.member" and
                fragment("?->>'membership'", e.content) == "invite",
            order_by: [desc: e.stream_ordering],
            limit: 1,
            select: e.sender
          )
        )

      sender != nil and MapSet.member?(ignored_users, sender)
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
