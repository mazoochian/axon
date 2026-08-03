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
  ancestor was unfetchable. This "drop the branch" leniency applies only
  to *internal* recursion inside an already-known ancestor's own history
  (`do_resolve_state_at/6`'s own prev_events walk) — see
  `resolve_for_auth_check/4` below for the very different rule that
  applies at the top level, to the PDU's own prev_events.

  ## Unknown top-level ancestor: refuse, don't guess

  If a *PDU's own* `prev_events` are all unresolvable (not locally known,
  and beyond what `AxonFederation.Backfill` could close — the common case
  is exactly one `prev_event`, so "all" and "the only one" coincide most
  of the time), `resolve_for_auth_check/4` returns `:unresolvable` rather
  than silently falling back to the room's current top state. Guessing
  here is actively wrong, not just imprecise: it would auth-check (and
  very likely accept) an event whose actual history this server does not
  have, against state that has nothing to do with that event's real
  ancestry. The caller (`AxonRoom.RoomProcess`) treats `:unresolvable` as
  a rejection — the event is stored
  (`AxonCore.EventStore.insert_rejected_event/2`) but never applied. When
  a PDU has *several* `prev_events` and only some are unresolvable, the
  resolvable ones are still used (same "drop the branch, don't guess an
  empty one" rule as the internal recursion above) — that's a real,
  DAG-grounded partial merge, not a guess against unrelated state, so it
  isn't refused.

  This does **not** affect the common paths that never reach this
  function in the first place: `needs_resolution?/2` already short-circuits
  to `false` (no resolution attempted, current_state used directly) for
  the by-far-most-common case of an ordinary `/send` PDU whose single
  `prev_event` is exactly this server's own current head, and for a
  brand-new room's initial `m.room.create` (`prev_events == []`). A
  `send_join`/`send_leave`/`send_knock` we're resident for normally lands
  in that same "matches our head" case too, since the joining server built
  it from a `/make_join` template sourced from our own state a moment
  earlier; only a genuine race (another event landed in between) would
  route it through real resolution, and in that case the referenced
  ancestor is — barring a real gap — something we already have. Joining
  *someone else's* room via `send_join` bypasses this module entirely
  (`AxonFederation.RoomJoin` inserts the state-snapshot events directly).
  Backfill catch-up (`AxonFederation.Backfill`) applies fetched events
  oldest-first specifically so each one's own `prev_events` are already
  persisted by the time it reaches this function; `:unresolvable` there
  means catch-up itself did not actually manage to close the gap for that
  event, which is exactly when refusing is correct.
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

  Returns `{:ok, state}`, or `:unresolvable` if `pdu` has at least one
  `prev_event` and *none* of them could be resolved (unknown locally,
  or beyond the walk cap) — see the "Unknown top-level ancestor" section
  of this module's doc for why that's a refusal rather than a guess.

  Note this is deliberately narrower than "any unresolved branch is
  refused": if `pdu` has *multiple* `prev_events` and only some are
  unresolvable, the resolvable ones still get used (same "drop the
  unknown branch" rule described above for `do_resolve_state_at/6`'s
  internal recursion — consistent behavior top-to-bottom, and it's a
  real, DAG-grounded partial merge, not a guess against unrelated state).
  Only the case this module's doc calls "the sharpest, most concrete
  bug" — a PDU whose ancestry resolves to *nothing* we know, so the old
  code substituted the room's unrelated current state — is refused here.
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

    case {prev_events, Enum.uniq(branch_states)} do
      # No prev_events at all (e.g. m.room.create) — nothing to resolve,
      # not a failure of any kind.
      {[], []} -> {:ok, current_state}
      # Had prev_events, but every single one was unresolvable.
      {_, []} -> :unresolvable
      {_, [single]} -> {:ok, single}
      {_, many} -> {:ok, StateResV2.resolve(many, &EventStore.get_event_map/1, room_version)}
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
