defmodule AxonRoom.StateResolver do
  @moduledoc """
  Detects when an inbound federation PDU needs state resolution before it
  can be auth-checked, and builds the resolved state set for that check.

  This closes a real gap: `RoomProcess` only tracks a single linear
  `current_state` (the room's state after the last event *we* applied). On
  the common "next event follows our head" path that's exactly right and
  no resolution is needed. But a PDU can arrive whose `prev_events` fork
  away from what we think is the head — either because it's a genuine
  merge point (two servers sent concurrent events, so it has more than one
  prev_event), or because we're catching up on events we hadn't seen yet.
  In both cases, blindly auth-checking against our single `current_state`
  is wrong: it reflects only one branch's history, not the state actually
  implied by this PDU's ancestry.

  `resolve_for_auth_check/4` computes the *real* resolved state at each of
  a PDU's `prev_events` — recursively, following `prev_events` as far back
  as needed through locally-known history, running `AxonRoom.StateResV2`
  at every branch point encountered along the way — not just a one-hop
  peek at a prev_event's own `auth_events` (the old, shallow approach,
  which could never produce a conflict spanning more than one generation
  and made room v12's MSC4297 "conflicted state subgraph" refinement
  unreachable regardless of whether it was implemented). Bounded to
  events already in our own DB: this does **not** fetch missing history
  from a remote server on a gap — no such fetch-then-retry path exists
  anywhere in this codebase today, and building one is a separate, larger
  feature than this module's scope.

  Implementation: a two-phase walk, not naive unbounded recursion.
  1. `prefetch_ancestors/2` does a capped, level-by-level breadth-first
     walk of `prev_events` (batch-fetching each level via
     `EventStore.get_event_maps/1`, one round trip per level instead of
     one per event) to build a small, bounded, in-memory map of
     everything the second phase might need. Trivially cycle-safe (a
     `MapSet` of already-seen ids), and this is the actual bound on total
     work: past the cap, further ancestors are simply treated the same
     as "not found locally" by phase 2 — dropped, not substituted with an
     empty state (see below).
  2. `resolve_state_at/6` folds that small in-memory map into resolved
     states, recursing purely over already-fetched data (no I/O), so its
     own recursion depth is cheap and bounded by the same cap. Marks each
     event as "in progress" in its cache *before* recursing into its
     `prev_events`, not after — needed because nothing validates on
     insert that a PDU's `prev_events`/`auth_events` actually resolve to
     already-known events, so out-of-order delivery (B referencing a
     not-yet-seen A, then A arriving referencing B) can produce a genuine
     2-cycle in local storage; post-order marking would infinite-loop on
     that.

  An ancestor that can't be resolved (not found locally, or beyond the
  cap) drops that whole branch from consideration rather than
  contributing an empty state map — an empty branch would make every key
  the *other*, fully-known branch has look conflicted (StateResV2 now
  treats "present in some but not all input sets" as conflicted, not a
  free pass — see its own moduledoc), forcing spurious re-auth-checks
  across a whole branch's untouched state just because one unrelated
  ancestor was unfetchable.
  """

  require Logger

  alias AxonCore.EventStore
  alias AxonRoom.{StateApplicator, StateResV2}

  # Ceiling on distinct events visited per top-level resolve_for_auth_check/4
  # call. This runs synchronously inside RoomProcess's single serializing
  # GenServer.call, so it's deliberately modest rather than generous — the
  # overwhelmingly common case (a PDU's prev_event matches our own head)
  # costs zero extra queries regardless, since it never even calls this.
  # Doubles as the absolute termination guarantee (past the cap, nothing
  # recurses further), not just a soft "everyday" limit.
  @walk_cap 500

  @doc "Whether `pdu` forks away from `last_event_id` and needs resolution before auth-checking."
  def needs_resolution?(pdu, last_event_id) do
    case pdu["prev_events"] || [] do
      [] -> false
      [^last_event_id] -> false
      _ -> true
    end
  end

  @doc """
  Builds the state set to auth-check `pdu` against: resolves the real
  state at each of `pdu`'s `prev_events` and merges them via
  `AxonRoom.StateResV2` wherever they disagree. `last_event_id` is
  `RoomProcess`'s own current head — the base case the walk bottoms out
  at in O(1) whenever a branch actually leads back to it, which is the
  common case even for a two-way merge (one branch is usually just "us").
  """
  def resolve_for_auth_check(pdu, current_state, last_event_id, room_version \\ "11") do
    prev_events = pdu["prev_events"] || []

    prefetched = prefetch_ancestors(prev_events, last_event_id)

    {branch_states, _cache} =
      Enum.reduce(prev_events, {[], %{}}, fn prev_id, {acc, cache} ->
        case resolve_state_at(
               prev_id,
               last_event_id,
               current_state,
               prefetched,
               room_version,
               cache
             ) do
          {:ok, state, cache} -> {[state | acc], cache}
          {:unknown, cache} -> {acc, cache}
        end
      end)

    case Enum.uniq(branch_states) do
      [] -> current_state
      [single] -> single
      many -> StateResV2.resolve(many, &EventStore.get_event_map/1, room_version)
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 1: capped, batched, cycle-safe breadth-first prefetch of prev_events
  # ancestry (a MapSet visited-set is inherently cycle-safe — a cycle just
  # stops the frontier from growing, no special-casing needed here).
  # ---------------------------------------------------------------------------

  defp prefetch_ancestors(start_ids, last_event_id) do
    initial_frontier = start_ids |> MapSet.new() |> MapSet.delete(last_event_id)
    walk_frontier(initial_frontier, MapSet.new([last_event_id]), %{})
  end

  defp walk_frontier(frontier, seen, acc) do
    frontier = MapSet.difference(frontier, seen)

    cond do
      MapSet.size(frontier) == 0 ->
        acc

      map_size(acc) + MapSet.size(frontier) > @walk_cap ->
        Logger.warning(
          "StateResolver: prev_events ancestor walk hit the #{@walk_cap}-event cap; " <>
            "resolving this PDU against partial history"
        )

        acc

      true ->
        # `rejected`/`soft_failed` aren't filtered here, same as
        # get_event_map/1 elsewhere in this codebase — currently harmless
        # (nothing sets those flags today; a failed auth check just skips
        # insert_event entirely) but worth revisiting the day soft-fail
        # persistence exists.
        fetched = EventStore.get_event_maps(MapSet.to_list(frontier))
        acc = Map.merge(acc, fetched)
        seen = MapSet.union(seen, frontier)

        next_frontier =
          fetched
          |> Map.values()
          |> Enum.flat_map(&(&1["prev_events"] || []))
          |> MapSet.new()

        walk_frontier(next_frontier, seen, acc)
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 2: fold the (small, already-fetched, in-memory) prefetched map into
  # resolved states. Pure computation, no I/O — cheap even though it's plain
  # recursion.
  # ---------------------------------------------------------------------------

  defp resolve_state_at(
         last_event_id,
         last_event_id,
         known_state,
         _prefetched,
         _room_version,
         cache
       ) do
    {:ok, known_state, Map.put(cache, last_event_id, known_state)}
  end

  defp resolve_state_at(event_id, last_event_id, known_state, prefetched, room_version, cache) do
    case Map.fetch(cache, event_id) do
      {:ok, :pending} ->
        {:unknown, cache}

      {:ok, :unknown} ->
        {:unknown, cache}

      {:ok, state} ->
        {:ok, state, cache}

      :error ->
        do_resolve_state_at(event_id, last_event_id, known_state, prefetched, room_version, cache)
    end
  end

  defp do_resolve_state_at(event_id, last_event_id, known_state, prefetched, room_version, cache) do
    case Map.fetch(prefetched, event_id) do
      :error ->
        {:unknown, Map.put(cache, event_id, :unknown)}

      {:ok, event} ->
        cache = Map.put(cache, event_id, :pending)
        prev_ids = event["prev_events"] || []

        {branch_states, cache} =
          Enum.reduce(prev_ids, {[], cache}, fn pid, {acc, cache} ->
            case resolve_state_at(
                   pid,
                   last_event_id,
                   known_state,
                   prefetched,
                   room_version,
                   cache
                 ) do
              {:ok, state, cache} -> {[state | acc], cache}
              {:unknown, cache} -> {acc, cache}
            end
          end)

        resolved_before =
          case Enum.uniq(branch_states) do
            [] -> %{}
            [single] -> single
            many -> StateResV2.resolve(many, &EventStore.get_event_map/1, room_version)
          end

        state_after = StateApplicator.apply(event, resolved_before)
        {:ok, state_after, Map.put(cache, event_id, state_after)}
    end
  end
end
