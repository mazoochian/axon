defmodule AxonWeb.SlidingSyncController do
  @moduledoc """
  Sliding sync (MSC4186) — `POST /_matrix/client/unstable/org.matrix.msc4186/sync`.

  A pragmatic subset of the MSC, not full conformance:

    * Invited and knocked rooms now participate in `lists`/`room_subscriptions`
      alongside joined ones — each gets `invite_state`/`knock_state` (stripped
      preview state, the same shape as classic `/sync`) instead of a
      timeline/required_state/counts, via the same `SyncHelpers.build_invite_state/2`
      classic sync uses so the two can't drift on what an invitee is allowed
      to see before joining. Left rooms are deliberately *not* given an
      equivalent bucket: unlike classic sync's incremental delta model
      (where a `leave` entry is the only signal a client gets), every
      sliding sync response here already re-sends a full `SYNC` op per
      range with no diffing (see below) — a room the user left simply stops
      appearing in the next response, which is itself the removal signal.
      Adding a real "you left" event would mean building the same
      incremental-delta plumbing classic sync has, for a signal this
      architecture already gives for free.
    * `sort` only ever behaves as `by_recency` (by each room's newest event),
      regardless of what the client requests.
    * Bandwidth diffing against a remembered `conn_id` session
      (`AxonWeb.SlidingSync.ConnState`): a request with no `conn_id` (or an
      empty one) gets a full `SYNC` op per range and a full entry for every
      visible room, every response — always spec-valid, and unchanged from
      before this existed. A client that sends the *same* `conn_id` on
      every request opts into diffing: a list range whose room_ids are
      identical to what was last sent on that connection has its `SYNC` op
      omitted entirely (the count is still reported), and a room whose full
      entry is byte-for-byte identical to what was last sent on that
      connection is omitted from `rooms` outright — the client already has
      it. Session state lives in ETS, TTL-swept, so losing it just falls
      back to a full resync on the next request.
    * Extension params aren't sticky across requests — a client must resend
      `"enabled": true` (and any config) on every request, not just the first
      time it turns an extension on.
    * `notification_count`/`highlight_count` are computed per room by
      re-evaluating this user's push rules (`AxonPush.RuleEvaluator`)
      against every event since their `m.read` receipt (room start if
      they've never sent one), capped at #{inspect(500)} scanned events —
      a room with more unread events than that undercounts rather than
      doing unbounded work on every sync poll. Real homeservers avoid the
      cap by maintaining a push-actions table incrementally as events
      arrive instead of recomputing on read; that's a bigger lift than
      this pass covers. Classic `/sync` doesn't get this (still always 0
      there) — kept local to sliding sync rather than promoted to the
      shared `SyncHelpers`, deliberately, to avoid claiming classic sync
      also changed.

  Long-poll wake-up reuses `AxonSync.Manager.wait_for_events/3` exactly as
  classic sync does, so the Phase 8 wake-up fixes (to-device, device-list,
  ephemeral) apply here too.
  """

  use Phoenix.Controller, formats: [:json]

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, Repo}
  alias AxonPush.{RuleEvaluator, UserRules}
  alias AxonSync.Manager, as: SyncManager
  alias AxonWeb.SlidingSync.ConnState
  alias AxonWeb.SyncHelpers

  @notification_scan_cap 500

  # POST /_matrix/client/unstable/org.matrix.msc4186/sync
  def sync(conn, params) do
    user_id = conn.assigns.current_user_id
    device_id = conn.assigns.current_device_id

    pos = params["pos"]
    timeout = min(String.to_integer(params["timeout"] || "0"), 30_000)
    is_initial = is_nil(pos)

    {since_ordering, dl_since, ad_since, _pr_since, left_since, eph_since} =
      SyncHelpers.parse_token(pos)

    lists_req = params["lists"] || %{}
    room_subscriptions_req = params["room_subscriptions"] || %{}
    extensions_req = params["extensions"] || %{}

    # Only a client that opts in by sending the same conn_id on every
    # request gets diffed against remembered session state — see
    # AxonWeb.SlidingSync.ConnState's moduledoc. Absent/empty conn_id keeps
    # today's always-full-resync behavior unchanged.
    conn_id =
      case params["conn_id"] do
        id when is_binary(id) and id != "" -> id
        _ -> nil
      end

    prior =
      if conn_id, do: ConnState.get(user_id, device_id, conn_id), else: %{lists: %{}, rooms: %{}}

    # Block for new activity the same way classic /sync does — a message,
    # to-device send, device-list touch, or ephemeral change all wake this.
    {_events_by_room, next_ordering} =
      if timeout > 0 do
        {:ok, by_room} = SyncManager.wait_for_events(user_id, since_ordering, timeout)
        {by_room, EventStore.current_max_stream_ordering()}
      else
        {%{}, EventStore.current_max_stream_ordering()}
      end

    next_ordering = max(next_ordering, since_ordering)

    joined_rooms = EventStore.get_joined_rooms(user_id)
    invited_rooms = EventStore.get_invited_rooms(user_id)
    knocked_rooms = EventStore.get_knocked_rooms(user_id)
    membership_by_room = membership_map(joined_rooms, invited_rooms, knocked_rooms)
    all_room_ids = joined_rooms ++ invited_rooms ++ knocked_rooms

    dm_ids = dm_room_ids(user_id)
    recency = EventStore.room_recency_map(all_room_ids)

    {lists_resp, room_configs_from_lists, new_lists_state} =
      build_lists(all_room_ids, recency, dm_ids, lists_req, prior.lists)

    subscribed_configs =
      room_subscriptions_req
      |> Enum.filter(fn {room_id, _cfg} -> room_id in all_room_ids end)
      |> Map.new()

    room_configs = merge_room_configs(room_configs_from_lists, subscribed_configs)

    {rooms_resp, new_rooms_state} =
      Enum.reduce(room_configs, {%{}, %{}}, fn {room_id, cfg}, {resp_acc, state_acc} ->
        membership = Map.fetch!(membership_by_room, room_id)
        entry = build_room_entry(room_id, user_id, cfg, is_initial, dm_ids, membership)
        fingerprint = room_fingerprint(entry)
        state_acc = Map.put(state_acc, room_id, fingerprint)

        resp_acc =
          if Map.get(prior.rooms, room_id) == fingerprint do
            resp_acc
          else
            Map.put(resp_acc, room_id, entry)
          end

        {resp_acc, state_acc}
      end)

    if conn_id do
      ConnState.put(user_id, device_id, conn_id, %{lists: new_lists_state, rooms: new_rooms_state})
    end

    visible_room_ids = Map.keys(room_configs)

    dl_next = SyncHelpers.current_dl_max_id()
    ad_next = SyncHelpers.current_ad_max_id()
    pr_next = AxonSync.Presence.current_version()
    left_next = SyncHelpers.current_left_max_id()
    eph_next = SyncHelpers.current_eph_max_id()

    new_pos =
      SyncHelpers.build_token(next_ordering, dl_next, ad_next, pr_next, left_next, eph_next)

    extensions_resp =
      build_extensions(
        user_id,
        device_id,
        is_initial,
        dl_since,
        left_since,
        ad_since,
        eph_since,
        extensions_req,
        visible_room_ids,
        new_pos
      )

    json(conn, %{
      "pos" => new_pos,
      "lists" => lists_resp,
      "rooms" => rooms_resp,
      "extensions" => extensions_resp
    })
  end

  # ---------------------------------------------------------------------------
  # Lists
  # ---------------------------------------------------------------------------

  # Returns {lists_response_map, %{room_id => merged_room_config}, new_lists_state}
  # — the config map feeds build_room_entry/5 for every room in any range
  # regardless of whether its range's op got diffed away below (its content
  # may still have changed even if the range's room_ids/ordering didn't);
  # new_lists_state is what AxonWeb.SlidingSync.ConnState should remember
  # for next time (only ranges present in *this* request, so a range the
  # client stops asking for is naturally dropped rather than kept forever).
  #
  # prior_lists is `prior.lists` from the caller's conn_id lookup — always
  # `%{}` when the request has no conn_id, which makes every range compare
  # as changed (nil != a list) and therefore always emit its SYNC op,
  # exactly matching pre-diffing behavior with no extra branching needed.
  defp build_lists(joined_rooms, recency, dm_ids, lists_req, prior_lists) do
    Enum.reduce(lists_req, {%{}, %{}, %{}}, fn {list_key, list_cfg},
                                               {lists_acc, configs_acc, lists_state_acc} ->
      filters = list_cfg["filters"] || %{}

      sorted_ids =
        joined_rooms
        |> Enum.filter(&room_matches_filters?(&1, filters, dm_ids))
        |> Enum.sort_by(&Map.get(recency, &1, 0), :desc)

      count = length(sorted_ids)
      ranges = normalize_ranges(list_cfg["ranges"], count)

      {ops, in_range_ids, lists_state_acc} =
        Enum.reduce(ranges, {[], [], lists_state_acc}, fn [start_idx, end_idx],
                                                          {ops_acc, ids_acc, state_acc} ->
          slice = Enum.slice(sorted_ids, start_idx, max(end_idx - start_idx + 1, 0))
          range_key = {list_key, start_idx, end_idx}
          state_acc = Map.put(state_acc, range_key, slice)

          ops_acc =
            if Map.get(prior_lists, range_key) == slice do
              ops_acc
            else
              [%{"op" => "SYNC", "range" => [start_idx, end_idx], "room_ids" => slice} | ops_acc]
            end

          {ops_acc, ids_acc ++ slice, state_acc}
        end)

      configs_acc =
        Enum.reduce(in_range_ids, configs_acc, fn room_id, acc ->
          Map.update(acc, room_id, list_cfg, &merge_config(&1, list_cfg))
        end)

      lists_acc = Map.put(lists_acc, list_key, %{"count" => count, "ops" => Enum.reverse(ops)})
      {lists_acc, configs_acc, lists_state_acc}
    end)
  end

  defp normalize_ranges(nil, count), do: [[0, max(count - 1, 0)]]
  defp normalize_ranges([], count), do: [[0, max(count - 1, 0)]]

  defp normalize_ranges(ranges, _count) when is_list(ranges) do
    Enum.map(ranges, fn
      [start_idx, end_idx] when is_integer(start_idx) and is_integer(end_idx) ->
        [max(start_idx, 0), end_idx]

      _other ->
        [0, 0]
    end)
  end

  defp room_matches_filters?(_room_id, filters, _dm_ids) when map_size(filters) == 0, do: true

  defp room_matches_filters?(room_id, filters, dm_ids) do
    Enum.all?(filters, fn
      {"is_dm", want} -> MapSet.member?(dm_ids, room_id) == want
      {"is_encrypted", want} -> SyncHelpers.room_encrypted?(room_id) == want
      # Unsupported filter key: don't exclude the room (documented gap).
      {_other, _want} -> true
    end)
  end

  defp dm_room_ids(user_id) do
    case Repo.one(
           from(a in "account_data",
             where: a.user_id == ^user_id and a.type == "m.direct",
             select: a.content
           )
         ) do
      content when is_map(content) ->
        content |> Map.values() |> List.flatten() |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  # Merge two list/room-subscription configs that both reference the same
  # room: union required_state entries, take the larger timeline_limit.
  defp merge_config(a, b) do
    %{
      "required_state" => Enum.uniq((a["required_state"] || []) ++ (b["required_state"] || [])),
      "timeline_limit" => max(a["timeline_limit"] || 0, b["timeline_limit"] || 0)
    }
  end

  defp merge_room_configs(from_lists, from_subscriptions) do
    Enum.reduce(from_subscriptions, from_lists, fn {room_id, cfg}, acc ->
      Map.update(acc, room_id, cfg, &merge_config(&1, cfg))
    end)
  end

  defp membership_map(joined_rooms, invited_rooms, knocked_rooms) do
    Map.new(joined_rooms, &{&1, :join})
    |> Map.merge(Map.new(invited_rooms, &{&1, :invite}))
    |> Map.merge(Map.new(knocked_rooms, &{&1, :knock}))
  end

  # ---------------------------------------------------------------------------
  # Per-room data
  # ---------------------------------------------------------------------------

  defp build_room_entry(room_id, user_id, _cfg, is_initial, dm_ids, :invite) do
    %{
      "initial" => is_initial,
      "invite_state" => %{"events" => SyncHelpers.build_invite_state(room_id, user_id)},
      "is_dm" => MapSet.member?(dm_ids, room_id)
    }
  end

  defp build_room_entry(room_id, user_id, _cfg, is_initial, dm_ids, :knock) do
    %{
      "initial" => is_initial,
      "knock_state" => %{"events" => EventStore.get_knock_preview_state(room_id, user_id)},
      "is_dm" => MapSet.member?(dm_ids, room_id)
    }
  end

  defp build_room_entry(room_id, user_id, cfg, is_initial, dm_ids, :join) do
    timeline_limit = cfg["timeline_limit"] || 0

    raw_timeline =
      if timeline_limit > 0 do
        EventStore.get_recent_room_events(room_id, timeline_limit, user_id)
      else
        []
      end

    timeline_maps = Enum.map(raw_timeline, &EventStore.event_to_map/1)

    required_state =
      resolve_required_state(room_id, user_id, cfg["required_state"] || [], raw_timeline)

    counts = EventStore.member_counts(room_id)
    unread = unread_counts(room_id, user_id)

    prev_batch =
      case raw_timeline do
        [] -> nil
        [first | _] -> Integer.to_string(first.stream_ordering - 1)
      end

    %{
      "name" => room_name(room_id),
      "avatar" => room_avatar(room_id),
      "initial" => is_initial,
      "required_state" => required_state,
      "timeline" => timeline_maps,
      "prev_batch" => prev_batch,
      "notification_count" => unread.notification_count,
      "highlight_count" => unread.highlight_count,
      "joined_count" => counts.joined,
      "invited_count" => counts.invited,
      "is_dm" => MapSet.member?(dm_ids, room_id)
    }
  end

  # A room's entry with "initial" dropped — that flag flips true -> false
  # between a room's first appearance on a connection and every later
  # response, so leaving it in would make every room look "changed" on
  # exactly its second response even when nothing else about it moved.
  # Everything else in the built entry (timeline, required_state, counts,
  # invite/knock state, name/avatar, is_dm) is real content, so plain map
  # equality is the whole comparison — no separate hashing needed.
  defp room_fingerprint(entry), do: Map.delete(entry, "initial")

  # ---------------------------------------------------------------------------
  # Notification/highlight counts
  # ---------------------------------------------------------------------------

  defp unread_counts(room_id, user_id) do
    since_ordering = read_receipt_ordering(room_id, user_id)
    rules = UserRules.effective_rules(user_id)

    room_id
    |> EventStore.get_events_since(since_ordering, @notification_scan_cap)
    |> Enum.reject(&(&1.sender == user_id))
    |> Enum.reduce(%{notification_count: 0, highlight_count: 0}, fn event, acc ->
      case RuleEvaluator.should_notify?(EventStore.event_to_map(event), room_id, user_id, rules) do
        {:notify, actions} ->
          acc = %{acc | notification_count: acc.notification_count + 1}
          if highlight?(actions), do: %{acc | highlight_count: acc.highlight_count + 1}, else: acc

        :dont_notify ->
          acc
      end
    end)
  end

  defp read_receipt_ordering(room_id, user_id) do
    receipt_event_id =
      Repo.one(
        from(r in "receipts",
          where: r.room_id == ^room_id and r.user_id == ^user_id and r.receipt_type == "m.read",
          select: r.event_id
        )
      )

    with event_id when not is_nil(event_id) <- receipt_event_id,
         {:ok, event} <- EventStore.get_event(event_id) do
      event.stream_ordering
    else
      _ -> 0
    end
  end

  defp highlight?(actions) do
    Enum.any?(actions, fn
      %{"set_tweak" => "highlight", "value" => value} -> value != false
      %{"set_tweak" => "highlight"} -> true
      _ -> false
    end)
  end

  defp room_name(room_id) do
    case EventStore.get_state_event(room_id, "m.room.name", "") do
      {:ok, event} -> get_in(event.content, ["name"])
      _ -> nil
    end
  end

  defp room_avatar(room_id) do
    case EventStore.get_state_event(room_id, "m.room.avatar", "") do
      {:ok, event} -> get_in(event.content, ["url"])
      _ -> nil
    end
  end

  # `requested` is a list of [type, state_key] pairs, with two special
  # state_key values: "$LAZY" (m.room.member only — only include senders
  # actually present in the returned timeline, plus the requesting user)
  # and "$ME" (substitute the requesting user's id). "*" is a type/state_key
  # wildcard.
  defp resolve_required_state(room_id, user_id, requested, raw_timeline) do
    full_state = EventStore.get_current_state(room_id)

    lazy_sender_ids =
      raw_timeline |> Enum.map(& &1.sender) |> Enum.uniq() |> MapSet.new() |> MapSet.put(user_id)

    requested
    |> Enum.filter(&match?([_, _], &1))
    |> Enum.flat_map(fn [type, state_key] ->
      cond do
        type == "m.room.member" and state_key == "$LAZY" ->
          Enum.filter(
            full_state,
            &(&1.type == "m.room.member" and MapSet.member?(lazy_sender_ids, &1.state_key))
          )

        state_key == "$ME" ->
          Enum.filter(full_state, &(&1.type == type and &1.state_key == user_id))

        type == "*" and state_key == "*" ->
          full_state

        type == "*" ->
          Enum.filter(full_state, &(&1.state_key == state_key))

        state_key == "*" ->
          Enum.filter(full_state, &(&1.type == type))

        true ->
          Enum.filter(full_state, &(&1.type == type and &1.state_key == state_key))
      end
    end)
    |> Enum.uniq_by(& &1.event_id)
    |> Enum.map(&EventStore.event_to_map/1)
  end

  # ---------------------------------------------------------------------------
  # Extensions
  # ---------------------------------------------------------------------------

  defp build_extensions(
         user_id,
         device_id,
         is_initial,
         dl_since,
         left_since,
         ad_since,
         eph_since,
         extensions_req,
         visible_room_ids,
         pos
       ) do
    %{}
    |> maybe_put_extension("to_device", extensions_req, fn cfg ->
      limit = cfg["limit"] || 100
      {events, _max_id} = SyncHelpers.drain_to_device_messages(user_id, device_id, limit)
      %{"events" => events, "next_batch" => pos}
    end)
    |> maybe_put_extension("e2ee", extensions_req, fn _cfg ->
      %{
        "device_one_time_keys_count" => SyncHelpers.get_otk_counts(user_id, device_id),
        "device_unused_fallback_key_types" =>
          SyncHelpers.get_unused_fallback_key_types(user_id, device_id),
        "device_lists" =>
          if is_initial do
            %{"changed" => [], "left" => []}
          else
            SyncHelpers.get_device_list_changes(user_id, dl_since, left_since)
          end
      }
    end)
    |> maybe_put_extension("account_data", extensions_req, fn _cfg ->
      global = SyncHelpers.get_global_account_data(user_id, is_initial, ad_since)

      rooms =
        visible_room_ids
        |> Enum.map(fn room_id ->
          {room_id, SyncHelpers.build_room_account_data(room_id, user_id)}
        end)
        |> Enum.reject(fn {_room_id, events} -> events == [] end)
        |> Map.new()

      %{"global" => global, "rooms" => rooms}
    end)
    |> maybe_put_extension("receipts", extensions_req, fn _cfg ->
      eph_floor = if is_initial, do: -1, else: eph_since

      rooms =
        visible_room_ids
        |> Enum.filter(&SyncHelpers.has_ephemeral_change?(&1, eph_floor))
        |> Enum.map(fn room_id ->
          case SyncHelpers.build_receipt_events(room_id) do
            [event] -> {room_id, event}
            [] -> {room_id, nil}
          end
        end)
        |> Enum.reject(fn {_room_id, event} -> is_nil(event) end)
        |> Map.new()

      %{"rooms" => rooms}
    end)
    |> maybe_put_extension("typing", extensions_req, fn _cfg ->
      rooms =
        Enum.into(visible_room_ids, %{}, fn room_id ->
          [event] = SyncHelpers.build_typing_event(room_id)
          {room_id, event}
        end)

      %{"rooms" => rooms}
    end)
  end

  defp maybe_put_extension(acc, key, extensions_req, build_fn) do
    case extensions_req[key] do
      %{"enabled" => true} = cfg -> Map.put(acc, key, build_fn.(cfg))
      _ -> acc
    end
  end
end
