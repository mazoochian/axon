defmodule AxonWeb.SyncController do
  @moduledoc """
  Classic `/sync` — `GET /_matrix/client/v3/sync`.

  `unread_notifications` (`notification_count`/`highlight_count`) per
  joined room is computed via `AxonWeb.SyncHelpers.unread_counts/2` — the
  same on-the-fly, capped-scan function sliding sync uses (see its doc for
  why on-the-fly was chosen over a maintained counter table), so the two
  endpoints can't report different numbers for the same room. Only sent
  for rooms already included in this response (gated by
  `build_rooms_response/6`'s existing new-events-or-ephemeral-change
  check) — a push-rule change with no accompanying event or receipt in a
  room won't refresh its badge until something else touches that room,
  same pre-existing incremental-diff limitation classic sync already has
  for everything else it sends.

  `unread_thread_notifications` (MSC in spec since Matrix 1.4, keyed by
  thread root event ID) is deliberately not sent: axon has no per-thread
  receipt or unread-tracking model anywhere (no `m.read` receipts scoped
  to a thread), so there is nothing correct to compute — omitting the key
  entirely is honest; a thread-aware client falls back to normal
  behavior, and a non-thread-aware one never looks for the key at all.
  """

  use Phoenix.Controller, formats: [:json]

  plug(AxonWeb.Plug.RateLimit, [bucket: :sync, key_by: :user] when action == :sync)

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, Repo}
  alias AxonSync.Manager, as: SyncManager
  alias AxonSync.Presence
  alias AxonWeb.EventController
  alias AxonWeb.SyncHelpers
  alias AxonWeb.TransactionIdProjection

  @default_timeline_limit 100

  # GET /_matrix/client/v3/sync
  def sync(conn, params) do
    user_id = conn.assigns.current_user_id
    device_id = conn.assigns.current_device_id
    since = params["since"]
    timeout = min(String.to_integer(params["timeout"] || "0"), 30_000)

    if params["set_presence"] in ["online", "unavailable", "offline"] do
      Presence.set_presence(user_id, params["set_presence"])
    end

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

    if timeout > 0 do
      {:ok, _events} = SyncManager.wait_for_events(user_id, since_ordering, timeout)
    end

    include_leave = get_in(filter, ["room", "include_leave"]) == true

    snapshot =
      EventStore.get_sync_snapshot(user_id, since_ordering,
        include_left: is_initial_sync and include_leave,
        include_new_left: not is_initial_sync
      )

    events_by_room = snapshot.events_by_room
    next_ordering = get_max_ordering(events_by_room, since_ordering)

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
      user_id
      |> build_rooms_response(
        events_by_room,
        snapshot.joined_rooms,
        snapshot.left_cutoffs,
        is_initial_sync,
        since_ordering,
        eph_since,
        filter
      )
      |> TransactionIdProjection.project_sync_rooms(user_id, device_id)

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

  # The "timeline"/"state" sub-object of a RoomEventFilter (spec §Filtering)
  # — kept as the raw map rather than pre-plucking `types` alone, since
  # `not_types`/`senders`/`not_senders` all need to survive the same trip
  # through `build_room_data/8` to `apply_event_filter/2` below.
  defp filter_timeline(filter), do: get_in(filter, ["room", "timeline"]) || %{}
  defp filter_state(filter), do: get_in(filter, ["room", "state"]) || %{}

  defp filter_timeline_limit(filter) do
    get_in(filter, ["room", "timeline", "limit"]) || @default_timeline_limit
  end

  # `types`/`senders` are allow-lists (only a match passes); `not_types`/
  # `not_senders` are deny-lists (a match is excluded) and win over the
  # corresponding allow-list per spec. Absent keys impose no constraint.
  defp apply_event_filter(events, filter) when is_map(filter) do
    types = filter["types"]
    not_types = filter["not_types"]
    senders = filter["senders"]
    not_senders = filter["not_senders"]

    Enum.filter(events, fn e ->
      (is_nil(types) or e["type"] in types) and
        (is_nil(not_types) or e["type"] not in not_types) and
        (is_nil(senders) or e["sender"] in senders) and
        (is_nil(not_senders) or e["sender"] not in not_senders)
    end)
  end

  defp apply_event_filter(events, _), do: events

  # ---------------------------------------------------------------------------
  # Sync response builder
  # ---------------------------------------------------------------------------

  defp build_rooms_response(
         user_id,
         events_by_room,
         joined_rooms,
         left_cutoffs,
         is_initial_sync,
         since_ordering,
         eph_since,
         filter
       ) do
    invited_rooms = EventStore.get_invited_rooms(user_id)
    tl_limit = filter_timeline_limit(filter)
    tl_filter = filter_timeline(filter)
    state_filter = filter_state(filter)

    join_response =
      joined_rooms
      |> Enum.reduce(%{}, fn room_id, acc ->
        # A joined member's timeline must not surface events from before
        # they had access under the room's history_visibility (e.g.
        # "joined"/"invited") — state (always sent in full, current
        # snapshot) and past-membership rooms (`leave_response`, already
        # bounded by their own leave_ordering) are unaffected. Cheap for
        # the common "shared"/"world_readable" case: `event_visible?/2`
        # short-circuits true without needing the extra ordering lookups.
        bounds = EventController.visibility_bounds(room_id, user_id)

        room_events =
          events_by_room
          |> Map.get(room_id, [])
          |> Enum.filter(&EventController.event_visible?(bounds, &1))

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
              tl_filter,
              state_filter
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
        invite_state = SyncHelpers.build_invite_state(room_id, user_id)
        {room_id, %{"invite_state" => %{"events" => invite_state}}}
      end)

    left_rooms = Map.keys(left_cutoffs)

    leave_response =
      Enum.into(left_rooms, %{}, fn room_id ->
        leave_cutoff = Map.fetch!(left_cutoffs, room_id)

        leave_events =
          events_by_room
          |> Map.get(room_id, [])
          |> Enum.filter(&(&1.stream_ordering <= leave_cutoff))

        filtered_leave_events =
          Enum.filter(leave_events, fn event ->
            event
            |> EventStore.event_to_map()
            |> then(&apply_event_filter([&1], tl_filter))
            |> Enum.any?()
          end)

        {limited, timeline_events} =
          if length(filtered_leave_events) > tl_limit do
            {true, Enum.take(filtered_leave_events, -tl_limit)}
          else
            {false, filtered_leave_events}
          end

        filtered_timeline = Enum.map(timeline_events, &EventStore.event_to_map/1)

        state_cutoff =
          case timeline_events do
            [first | _] when limited -> first.stream_ordering
            [] when limited -> :all
            _ -> :none
          end

        state_events =
          leave_events
          |> Enum.filter(fn event ->
            event.state_key != nil and
              (state_cutoff == :all or
                 (is_integer(state_cutoff) and event.stream_ordering < state_cutoff))
          end)
          |> Enum.reduce(%{}, fn event, state ->
            Map.put(state, {event.type, event.state_key}, event)
          end)
          |> Map.values()
          |> Enum.sort_by(& &1.stream_ordering)
          |> Enum.map(&EventStore.event_to_map/1)
          |> apply_event_filter(state_filter)

        prev_batch =
          case timeline_events do
            [first | _] when limited -> Integer.to_string(first.stream_ordering)
            [] when limited -> Integer.to_string(leave_cutoff + 1)
            [] -> Integer.to_string(leave_cutoff)
            events -> Integer.to_string(List.last(events).stream_ordering)
          end

        {room_id,
         %{
           "timeline" => %{
             "events" => filtered_timeline,
             "limited" => limited,
             "prev_batch" => prev_batch
           },
           "state" => %{"events" => state_events}
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
         tl_filter,
         state_filter
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
            tl_filter,
            since_ordering
          )

        true ->
          build_incremental_room_data(room_events, tl_limit, since_ordering)
      end

    # Apply the event filter to the state section (independently of the
    # timeline filter below — a type excluded from the timeline is not
    # implicitly excluded from state, and vice versa; see moduledoc note
    # on `build_incremental_room_data/3` for why the state/timeline split
    # itself happens *before* either filter is applied).
    filtered_state = apply_event_filter(state_events, state_filter)
    # Apply the event filter to the timeline
    filtered_timeline = apply_event_filter(timeline_events, tl_filter)

    ephemeral =
      SyncHelpers.build_receipt_events(room_id) ++
        SyncHelpers.build_typing_event(room_id, is_initial_sync)

    room_account_data = SyncHelpers.build_room_account_data(room_id, user_id)

    # Add unsigned.membership to timeline events (MSC4115)
    timeline_with_membership = add_membership_to_timeline(filtered_timeline, room_id, user_id)
    # Bundle reaction/thread aggregations (unsigned.m.relations)
    timeline_with_relations =
      EventStore.bundle_relations(room_id, timeline_with_membership, user_id: user_id)

    unread = SyncHelpers.unread_counts(room_id, user_id)
    counts = EventStore.member_counts(room_id)

    %{
      "timeline" => %{
        "events" => timeline_with_relations,
        "limited" => limited,
        "prev_batch" => prev_batch
      },
      "state" => %{"events" => filtered_state},
      "account_data" => %{"events" => room_account_data},
      "ephemeral" => %{"events" => ephemeral},
      "summary" => %{
        "m.joined_member_count" => counts.joined,
        "m.invited_member_count" => counts.invited
      },
      "unread_notifications" => %{
        "notification_count" => unread.notification_count,
        "highlight_count" => unread.highlight_count
      }
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
      cond do
        limited and tl_events != [] ->
          # There's earlier history this response didn't include — point
          # to just before it, so backward /messages pagination picks up
          # where this chunk left off.
          #
          # This must be `hd(tl_events).stream_ordering` itself, NOT
          # `- 1` (Complement: TestNetworkPartitionOrdering). EventStore.
          # get_messages/4's dir=b bound is `stream_ordering <
          # from_ordering` — already exclusive of `from_ordering` — so
          # passing the earliest timeline event's own ordering already
          # excludes that event and admits everything strictly before
          # it, which is exactly "pick up where this chunk left off".
          # Subtracting 1 first over-excludes by one: it silently drops
          # the single room event immediately preceding this timeline
          # window off the very next backward page (a client using this
          # prev_batch to paginate never sees that event, in `/messages`
          # or anywhere else — /sync only handed it the newer window).
          Integer.to_string(hd(tl_events).stream_ordering)

        tl_events != [] ->
          # Not limited: every event this room has is already in
          # `tl_events`. There's nothing earlier to page to, but this
          # token is also the room's contribution to a `GET
          # /members?at=` point-in-time query (see
          # EventStore.get_room_members_at/3's `<=` semantics) — it
          # must resolve to "membership as observed in *this* response"
          # rather than "before this room existed", or every full
          # initial sync hands out a token that answers every `at=`
          # query with an empty chunk. The tail (most recent) event's
          # own ordering is the right boundary for that: inclusive of
          # everything this response actually showed, exclusive of
          # anything that happens afterward (e.g. a later join).
          Integer.to_string(List.last(tl_events).stream_ordering)

        true ->
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
         _tl_filter,
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
        # No `- 1` — see build_initial_room_data/4's matching branch for
        # why: get_messages/4's dir=b bound is already exclusive of
        # `from_ordering`, so the earliest timeline event's own ordering
        # is already the correct "everything strictly before here"
        # pagination boundary (Complement: TestNetworkPartitionOrdering).
        Integer.to_string(hd(tl_events).stream_ordering)
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

    prev =
      cond do
        limited and tl_events != [] ->
          # No `- 1` — same boundary this function's own `cutoff` above
          # already uses with a strict `<`, and the same reasoning as
          # build_initial_room_data/4's matching branch: get_messages/4's
          # dir=b bound is already exclusive of `from_ordering`
          # (Complement: TestNetworkPartitionOrdering).
          Integer.to_string(hd(tl_events).stream_ordering)

        tl_events != [] ->
          # Not limited: see build_initial_room_data/4's matching branch —
          # same "this token must mean *as of this response*" reasoning.
          Integer.to_string(List.last(tl_events).stream_ordering)

        true ->
          # No events in this room's window at all (only got here for
          # an ephemeral-only change) — the response's own snapshot is
          # unchanged from where the client already was.
          Integer.to_string(since_ordering)
      end

    {state_events, Enum.map(tl_events, &EventStore.event_to_map/1), limited, prev}
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
