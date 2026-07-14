defmodule AxonWeb.SlidingSyncController do
  @moduledoc """
  Sliding sync (MSC4186) — `POST /_matrix/client/unstable/org.matrix.msc4186/sync`.

  A pragmatic subset of the MSC, not full conformance:

    * Only joined rooms participate in `lists`/`room_subscriptions` — invited/
      knocked/left rooms aren't exposed here yet (classic `/sync`, kept
      alongside this endpoint, still covers those). Exposing them safely
      would mean re-deriving the same invite-state-only visibility rules
      `SyncController.build_invite_state/2` already enforces for classic
      sync; deferred rather than half-done.
    * `sort` only ever behaves as `by_recency` (by each room's newest event),
      regardless of what the client requests.
    * Every response re-sends a full `SYNC` op per range rather than diffing
      against a remembered previous window (no `conn_id` session state is
      kept) — correct per spec (a full re-sync is always a valid response),
      just less bandwidth-efficient than real add/remove diffing.
    * Extension params aren't sticky across requests — a client must resend
      `"enabled": true` (and any config) on every request, not just the first
      time it turns an extension on.
    * `notification_count`/`highlight_count` are always 0 — this codebase
      doesn't compute per-room unread/highlight counts anywhere yet (not
      even in classic `/sync` or push dispatch), so this isn't a regression,
      just a shared known gap.

  Long-poll wake-up reuses `AxonSync.Manager.wait_for_events/3` exactly as
  classic sync does, so the Phase 8 wake-up fixes (to-device, device-list,
  ephemeral) apply here too.
  """

  use Phoenix.Controller, formats: [:json]

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, Repo}
  alias AxonSync.Manager, as: SyncManager
  alias AxonWeb.SyncHelpers

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
    dm_ids = dm_room_ids(user_id)
    recency = EventStore.room_recency_map(joined_rooms)

    {lists_resp, room_configs_from_lists} =
      build_lists(joined_rooms, recency, dm_ids, lists_req)

    subscribed_configs =
      room_subscriptions_req
      |> Enum.filter(fn {room_id, _cfg} -> room_id in joined_rooms end)
      |> Map.new()

    room_configs = merge_room_configs(room_configs_from_lists, subscribed_configs)

    rooms_resp =
      Enum.into(room_configs, %{}, fn {room_id, cfg} ->
        {room_id, build_room_entry(room_id, user_id, cfg, is_initial, dm_ids)}
      end)

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

  # Returns {lists_response_map, %{room_id => merged_room_config}} — the
  # latter feeds build_room_entry/5 for every room that appears in any list.
  defp build_lists(joined_rooms, recency, dm_ids, lists_req) do
    Enum.reduce(lists_req, {%{}, %{}}, fn {list_key, list_cfg}, {lists_acc, configs_acc} ->
      filters = list_cfg["filters"] || %{}

      sorted_ids =
        joined_rooms
        |> Enum.filter(&room_matches_filters?(&1, filters, dm_ids))
        |> Enum.sort_by(&Map.get(recency, &1, 0), :desc)

      count = length(sorted_ids)
      ranges = normalize_ranges(list_cfg["ranges"], count)

      {ops, in_range_ids} =
        Enum.map_reduce(ranges, [], fn [start_idx, end_idx], acc ->
          slice = Enum.slice(sorted_ids, start_idx, max(end_idx - start_idx + 1, 0))
          {%{"op" => "SYNC", "range" => [start_idx, end_idx], "room_ids" => slice}, acc ++ slice}
        end)

      configs_acc =
        Enum.reduce(in_range_ids, configs_acc, fn room_id, acc ->
          Map.update(acc, room_id, list_cfg, &merge_config(&1, list_cfg))
        end)

      {Map.put(lists_acc, list_key, %{"count" => count, "ops" => ops}), configs_acc}
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

  # ---------------------------------------------------------------------------
  # Per-room data
  # ---------------------------------------------------------------------------

  defp build_room_entry(room_id, user_id, cfg, is_initial, dm_ids) do
    timeline_limit = cfg["timeline_limit"] || 0

    raw_timeline =
      if timeline_limit > 0 do
        EventStore.get_recent_room_events(room_id, timeline_limit)
      else
        []
      end

    timeline_maps = Enum.map(raw_timeline, &EventStore.event_to_map/1)

    required_state =
      resolve_required_state(room_id, user_id, cfg["required_state"] || [], raw_timeline)

    counts = EventStore.member_counts(room_id)

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
      "notification_count" => 0,
      "highlight_count" => 0,
      "joined_count" => counts.joined,
      "invited_count" => counts.invited,
      "is_dm" => MapSet.member?(dm_ids, room_id)
    }
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
