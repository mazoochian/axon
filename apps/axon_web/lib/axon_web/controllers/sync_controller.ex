defmodule AxonWeb.SyncController do
  use Phoenix.Controller, formats: [:json]

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, KeyStore, Repo}
  alias AxonSync.Manager, as: SyncManager
  alias AxonSync.Presence

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
      parse_sync_token(since)

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
    dl_next = current_dl_max_id()
    ad_next = current_ad_max_id()
    pr_next = Presence.current_version()
    left_next = current_left_max_id()
    eph_next = current_eph_max_id()
    next_batch = "#{next_ordering}_#{dl_next}_#{ad_next}_#{pr_next}_#{left_next}_#{eph_next}"

    rooms_response =
      build_rooms_response(
        user_id,
        events_by_room,
        is_initial_sync,
        since_ordering,
        eph_since,
        filter
      )

    global_account_data = get_global_account_data(user_id, is_initial_sync, ad_since)
    presence_events = get_presence_events(user_id, is_initial_sync, pr_since)

    # E2EE sync additions
    {to_device_events, _max_tdm_id} = drain_to_device_messages(user_id, device_id)
    otk_counts = get_otk_counts(user_id, device_id)
    unused_fallback_types = get_unused_fallback_key_types(user_id, device_id)

    device_lists =
      if is_initial_sync do
        %{"changed" => [], "left" => []}
      else
        get_device_list_changes(user_id, dl_since, left_since)
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
        has_new_events = room_events != [] or has_ephemeral_change?(room_id, eph_since)

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

    ephemeral = build_ephemeral(room_id)
    room_account_data = build_room_account_data(room_id, user_id)

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

  # Returns {room_ordering, dl_cursor, ad_cursor, pr_cursor, left_cursor, eph_cursor}.
  # Token format: "${room_ordering}_${dl_cursor}_${ad_cursor}_${pr_cursor}_${left_cursor}_${eph_cursor}"
  # Older, shorter tokens default the missing cursor(s) to 0 (return
  # everything for that stream on the next sync).
  defp parse_sync_token(nil), do: {0, 0, 0, 0, 0, 0}

  defp parse_sync_token(since) do
    parse_int = fn s ->
      case Integer.parse(s) do
        {n, _} -> n
        _ -> 0
      end
    end

    parts = String.split(since, "_")
    room_n = parse_int.(Enum.at(parts, 0, "0"))
    dl_n = parse_int.(Enum.at(parts, 1, "0"))
    ad_n = parse_int.(Enum.at(parts, 2, "0"))
    pr_n = parse_int.(Enum.at(parts, 3, "0"))
    left_n = parse_int.(Enum.at(parts, 4, "0"))
    eph_n = parse_int.(Enum.at(parts, 5, "0"))
    {room_n, dl_n, ad_n, pr_n, left_n, eph_n}
  end

  defp build_room_account_data(room_id, user_id) do
    Repo.all(
      from(r in "room_account_data",
        where: r.room_id == ^room_id and r.user_id == ^user_id,
        select: %{type: r.type, content: r.content}
      )
    )
    |> Enum.map(fn r -> %{"type" => r.type, "content" => r.content} end)
  end

  defp build_ephemeral(room_id) do
    build_receipt_events(room_id) ++ build_typing_event(room_id)
  end

  defp build_receipt_events(room_id) do
    receipts =
      Repo.all(
        from(r in "receipts",
          where: r.room_id == ^room_id and r.receipt_type in ["m.read", "m.read.private"],
          select: %{
            user_id: r.user_id,
            receipt_type: r.receipt_type,
            event_id: r.event_id,
            ts: r.ts
          }
        )
      )

    if receipts == [] do
      []
    else
      content =
        Enum.reduce(receipts, %{}, fn r, acc ->
          user_entry = %{"ts" => r.ts}
          type_map = Map.get(acc, r.event_id, %{})
          users_map = Map.get(type_map, r.receipt_type, %{})

          updated_type_map =
            Map.put(type_map, r.receipt_type, Map.put(users_map, r.user_id, user_entry))

          Map.put(acc, r.event_id, updated_type_map)
        end)

      [%{"type" => "m.receipt", "content" => content}]
    end
  end

  # Unlike receipts (only included when non-empty), typing is always
  # included whenever the room is in the response at all — the room only
  # got here because something ephemeral changed, and an empty user_ids
  # list is itself meaningful (someone stopped typing).
  defp build_typing_event(room_id) do
    [
      %{
        "type" => "m.typing",
        "content" => %{"user_ids" => AxonSync.Typing.typing_user_ids(room_id)}
      }
    ]
  end

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

  # Initial sync: return all account_data for the user.
  # Incremental sync: return only types that changed since ad_since (account_data_stream cursor).
  defp get_global_account_data(user_id, _is_initial = true, _ad_since) do
    Repo.all(
      from(a in "account_data",
        where: a.user_id == ^user_id,
        select: %{type: a.type, content: a.content}
      )
    )
    |> Enum.map(fn a -> %{"type" => a.type, "content" => a.content} end)
  end

  defp get_global_account_data(user_id, _is_initial = false, ad_since) do
    changed_types =
      Repo.all(
        from(s in "account_data_stream",
          where: s.user_id == ^user_id and s.id > ^ad_since,
          select: s.type,
          distinct: true
        )
      )

    if changed_types == [] do
      []
    else
      Repo.all(
        from(a in "account_data",
          where: a.user_id == ^user_id and a.type in ^changed_types,
          select: %{type: a.type, content: a.content}
        )
      )
      |> Enum.map(fn a -> %{"type" => a.type, "content" => a.content} end)
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

  # ---------------------------------------------------------------------------
  # E2EE sync helpers
  # ---------------------------------------------------------------------------

  # Atomically fetch and delete pending to-device messages for this device.
  # Returns {events_list, max_id_delivered}.
  defp drain_to_device_messages(user_id, device_id) do
    rows =
      Repo.all(
        from(m in "to_device_messages",
          where: m.target_user_id == ^user_id and m.target_device_id == ^device_id,
          order_by: [asc: m.id],
          limit: 100,
          select: %{id: m.id, sender: m.sender, type: m.type, content: m.content}
        )
      )

    if rows != [] do
      ids = Enum.map(rows, & &1.id)
      Repo.delete_all(from(m in "to_device_messages", where: m.id in ^ids))
    end

    events =
      Enum.map(rows, fn row ->
        %{"type" => row.type, "sender" => row.sender, "content" => row.content}
      end)

    max_id = if rows == [], do: 0, else: List.last(rows).id
    {events, max_id}
  end

  defp get_otk_counts(user_id, device_id) do
    Repo.all(
      from(k in "one_time_keys",
        where: k.user_id == ^user_id and k.device_id == ^device_id and k.claimed == false,
        group_by: k.algorithm,
        select: {k.algorithm, count(k.id)}
      )
    )
    |> Enum.into(%{})
  end

  # Returns list of algorithm names for which an unused fallback key exists.
  # Clients use this to know which algorithms still have fallback coverage.
  defp get_unused_fallback_key_types(user_id, device_id) do
    Repo.all(
      from(fk in "fallback_keys",
        where: fk.user_id == ^user_id and fk.device_id == ^device_id and fk.used == false,
        select: fk.algorithm
      )
    )
  end

  # Returns %{"changed" => [...], "left" => [...]}.
  # `changed`: users sharing a room with `user_id` whose keys changed, or who
  # newly share a room with `user_id`, since `dl_since` (see
  # AxonCore.EventStore's device-list touch on room join).
  # `left`: users `user_id` no longer shares any room with, since `left_since`
  # (see AxonCore.EventStore's device_list_partings on room leave).
  defp get_device_list_changes(user_id, dl_since, left_since) do
    # The user must see their own device-list changes (new logins, cross-signing
    # uploads) so their other devices re-query keys — spec requires self in `changed`.
    candidate_users = [user_id | shared_room_user_ids(user_id)]

    changed =
      Repo.all(
        from(u in "device_list_updates",
          where: u.user_id in ^candidate_users and u.id > ^dl_since,
          select: u.user_id,
          distinct: true
        )
      )

    left = KeyStore.device_list_partings_since(user_id, left_since)

    %{"changed" => changed, "left" => left}
  end

  defp shared_room_user_ids(user_id) do
    Repo.all(
      from(m2 in "room_memberships",
        join: m1 in "room_memberships",
        on: m1.room_id == m2.room_id and m1.user_id == ^user_id and m1.membership == "join",
        where: m2.membership == "join" and m2.user_id != ^user_id,
        select: m2.user_id,
        distinct: true
      )
    )
  end

  # Presence for the user themselves plus anyone sharing a joined room with
  # them. Initial sync returns everyone's current state; incremental sync
  # returns only those whose presence changed since pr_since.
  defp get_presence_events(user_id, is_initial_sync, pr_since) do
    candidate_users = [user_id | shared_room_user_ids(user_id)]

    presence_by_user =
      if is_initial_sync do
        Enum.into(candidate_users, %{}, fn uid -> {uid, Presence.get(uid)} end)
      else
        Presence.changes_since(candidate_users, pr_since)
      end

    Enum.map(presence_by_user, fn {uid, presence} ->
      %{"type" => "m.presence", "sender" => uid, "content" => presence}
    end)
  end

  defp current_dl_max_id do
    Repo.one(from(u in "device_list_updates", select: max(u.id))) || 0
  end

  defp current_ad_max_id do
    Repo.one(from(s in "account_data_stream", select: max(s.id))) || 0
  end

  defp current_left_max_id do
    Repo.one(from(p in "device_list_partings", select: max(p.id))) || 0
  end

  defp current_eph_max_id do
    Repo.one(from(e in "ephemeral_updates", select: max(e.id))) || 0
  end

  defp has_ephemeral_change?(room_id, eph_since) do
    Repo.exists?(
      from(e in "ephemeral_updates", where: e.room_id == ^room_id and e.id > ^eph_since)
    )
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
