defmodule AxonRoom.StateResV2 do
  @moduledoc """
  Matrix State Resolution v2, plus room-v12's MSC4297 "state resolution
  v2.1" refinements to it (spec: https://spec.matrix.org/v1.18/rooms/v12/):

    1. Iterative auth checks start from an empty state map instead of the
       unconflicted state map (unconflicted is merged back in only once,
       at the very end — see `resolve/3`'s `room_version` branch below).
    2. The *full conflicted set* additionally includes the *conflicted
       state subgraph*: "starting from an event in the conflicted state
       set and following auth_events edges may lead to another event in
       the conflicted state set. The union of all such paths between any
       pair of events in the conflicted state set (including endpoints)
       forms a subgraph of the original auth_event graph" — an
       intermediate ancestor that lies between two conflicted-set events
       but would otherwise be excluded (because it's also reachable from
       some *unconflicted* value's own ancestry) needs to survive replay
       too, not be silently trusted as already-settled.

  Both are gated on `room_version == "12"`; versions 2-11 keep the
  original v2 behavior throughout.

  Two correctness fixes applied to *all* versions, found while verifying
  the above against spec (both were latent — no test before now exercised
  a real multi-generation fork, so neither had ever been observed to
  matter):

    - The iterative auth-check fold applies `with_auth_event_fallback/3`
      before each `AuthRules.check/3` call — spec's "iterative auth
      checks algorithm": "If a (event_type, state_key) key that is
      required for checking the authorization rules is not present in
      the state, then the appropriate state event from the event's
      auth_events is used." Matters most for v12 (which starts replay
      from a genuinely empty map — pre-12's unconflicted-merge usually
      papered over this in practice), but is part of the shared
      algorithm, not a v12-only concern.
    - `reverse_topological_power_ordering/3`'s tie-break used to sort by
      `-depth` (descending), the opposite of spec (ties resolve with the
      *newer* event winning) and of this code's own prior comment —
      letting an older ancestor pulled into the replay set via
      `auth_diff` outrank its own newer descendants.

  Spec: https://spec.matrix.org/v1.18/rooms/v2/#state-resolution
  Used for room versions 2+.
  """

  alias AxonRoom.AuthRules

  @type event_map :: %{String.t() => any()}
  @type state_key :: {String.t(), String.t()}
  @type state_set :: %{state_key() => event_map()}

  @doc """
  Resolves a list of state sets into a single resolved state.

  `get_event_fn` fetches an event map by event_id (returns nil if not found).
  """
  @spec resolve([state_set()], (String.t() -> event_map() | nil), String.t()) :: state_set()
  def resolve(state_sets, get_event_fn, room_version \\ "11")
  def resolve([], _, _), do: %{}
  def resolve([single], _, _), do: single

  def resolve(state_sets, get_event_fn, room_version) do
    all_keys =
      state_sets
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    # Spec: a key is unconflicted only if it's present with the same value in
    # EVERY input state set — not merely "only one distinct value across
    # whichever sets happen to have an opinion." A key present in some sets
    # and absent from others is conflicted too (the absent sets simply have
    # no opinion; they don't get to veto the auth-check the present value
    # must still survive). Getting this wrong lets a value skip
    # AuthRules.check entirely just because it was the sole candidate.
    {unconflicted, conflicted_events} =
      Enum.reduce(all_keys, {%{}, MapSet.new()}, fn key, {unc, conf} ->
        present_values =
          state_sets
          |> Enum.map(&Map.get(&1, key))
          |> Enum.reject(&is_nil/1)

        distinct = Enum.uniq_by(present_values, & &1["event_id"])

        cond do
          present_values == [] ->
            {unc, conf}

          length(present_values) == length(state_sets) and length(distinct) == 1 ->
            {Map.put(unc, key, hd(distinct)), conf}

          true ->
            {unc, Enum.reduce(distinct, conf, &MapSet.put(&2, &1))}
        end
      end)

    if MapSet.size(conflicted_events) == 0 do
      unconflicted
    else
      conflicted_list = MapSet.to_list(conflicted_events)
      conflicted_ids = MapSet.new(conflicted_list, & &1["event_id"])

      # Auth chains of conflicted events (excluding the conflicted events themselves)
      conflicted_chain =
        conflicted_list
        |> Enum.flat_map(&auth_chain(&1, get_event_fn))
        |> Enum.uniq_by(& &1["event_id"])
        |> Enum.reject(&MapSet.member?(conflicted_ids, &1["event_id"]))

      # Auth chain IDs of unconflicted state (to subtract from auth_diff)
      unconflicted_chain_ids =
        unconflicted
        |> Map.values()
        |> Enum.flat_map(&auth_chain_ids(&1, get_event_fn))
        |> MapSet.new()

      auth_diff =
        Enum.reject(conflicted_chain, &MapSet.member?(unconflicted_chain_ids, &1["event_id"]))

      full_conflicted =
        if room_version == "12" do
          subgraph = conflicted_state_subgraph(conflicted_chain, conflicted_ids, get_event_fn)
          (conflicted_list ++ subgraph ++ auth_diff) |> Enum.uniq_by(& &1["event_id"])
        else
          conflicted_list ++ auth_diff
        end

      sorted = reverse_topological_power_ordering(full_conflicted, auth_diff, get_event_fn)

      resolved =
        Enum.reduce(sorted, %{}, fn event, resolved_so_far ->
          # Room v12 (MSC4297): start from resolved_so_far alone, not merged
          # with unconflicted — this is precisely the change that protects
          # against state resets; unconflicted state is folded back in only
          # once, below, after the whole iteration finishes. Versions before
          # 12 keep the original v2 behavior of checking against
          # unconflicted-plus-resolved-so-far at every step.
          check_state =
            if room_version == "12",
              do: resolved_so_far,
              else: Map.merge(unconflicted, resolved_so_far)

          # Spec ("iterative auth checks algorithm"): "If a (event_type,
          # state_key) key that is required for checking the authorization
          # rules is not present in the state, then the appropriate state
          # event from the event's auth_events is used." Matters most for
          # v12: unlike pre-12's unconflicted-merge (which usually already
          # covers this in practice), v12 starts truly empty, so a
          # perfectly legitimate event's own sender-membership/power_levels
          # ancestor — genuinely unconflicted, hence never itself part of
          # `sorted` — would otherwise never be visible during replay at
          # all, and every check requiring it would spuriously fail. Never
          # overrides a key check_state already has an opinion on.
          check_state = with_auth_event_fallback(event, check_state, get_event_fn)

          if state_event?(event) and AuthRules.check(event, check_state, room_version) == :ok do
            key = {event["type"], event["state_key"]}
            Map.put(resolved_so_far, key, event)
          else
            resolved_so_far
          end
        end)

      Map.merge(unconflicted, resolved)
    end
  end

  defp with_auth_event_fallback(event, check_state, get_event_fn) do
    (event["auth_events"] || [])
    |> Enum.reduce(check_state, fn auth_id, acc ->
      case get_event_fn.(auth_id) do
        %{"state_key" => sk, "type" => t} = auth_event ->
          key = {t, sk}
          if Map.has_key?(acc, key), do: acc, else: Map.put(acc, key, auth_event)

        _ ->
          acc
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Auth chain traversal
  # ---------------------------------------------------------------------------

  defp auth_chain(event, get_event_fn, visited \\ MapSet.new()) do
    auth_ids = event["auth_events"] || []

    Enum.flat_map(auth_ids, fn auth_id ->
      if MapSet.member?(visited, auth_id) do
        []
      else
        case get_event_fn.(auth_id) do
          nil -> []
          ae -> [ae | auth_chain(ae, get_event_fn, MapSet.put(visited, auth_id))]
        end
      end
    end)
  end

  defp auth_chain_ids(event, get_event_fn) do
    event
    |> auth_chain(get_event_fn)
    |> Enum.map(& &1["event_id"])
  end

  # ---------------------------------------------------------------------------
  # Conflicted state subgraph (room v12 / MSC4297)
  # ---------------------------------------------------------------------------

  # n belongs in the subgraph iff n is backward-reachable from some
  # conflicted-set event (n ∈ conflicted_chain, already ancestors of the
  # full conflicted_list) AND some conflicted-set event is itself an
  # ancestor of n — i.e. n lies on a path between two conflicted-set
  # events, not merely a shared ancestor of one (a common root like
  # m.room.create correctly has nothing conflicted in *its own* ancestry,
  # so it's excluded).
  #
  # Computed as a single memoized bottom-up pass, not a per-node
  # auth_chain_ids/2 call: conflicted_chain's size is bounded by the depth
  # of the conflicted events' auth history, which is exactly what grows
  # large in the deep-fork scenarios this feature targets — an unmemoized
  # full traversal per node would be an O(V²)-ish pass, not O(V+E).
  defp conflicted_state_subgraph(conflicted_chain, conflicted_ids, get_event_fn) do
    {result, _memo} =
      Enum.reduce(conflicted_chain, {[], %{}}, fn event, {acc, memo} ->
        {reachable, memo} =
          reachable_conflicted_ids(event["event_id"], conflicted_ids, get_event_fn, memo)

        if MapSet.size(reachable) > 0, do: {[event | acc], memo}, else: {acc, memo}
      end)

    result
  end

  # Returns {set of conflicted_ids reachable in event_id's own auth
  # ancestry, updated memo}. "In progress" (:pending) marks an id before
  # recursing into its own auth_events, not after — same cycle-safety
  # reasoning as AxonRoom.StateResolver's ancestor walk: nothing guarantees
  # an acyclic auth_events graph against out-of-order/adversarial input.
  defp reachable_conflicted_ids(event_id, conflicted_ids, get_event_fn, memo) do
    case Map.fetch(memo, event_id) do
      {:ok, :pending} ->
        {MapSet.new(), memo}

      {:ok, cached} ->
        {cached, memo}

      :error ->
        memo = Map.put(memo, event_id, :pending)

        case get_event_fn.(event_id) do
          nil ->
            {MapSet.new(), Map.put(memo, event_id, MapSet.new())}

          event ->
            auth_ids = event["auth_events"] || []

            {reachable, memo} =
              Enum.reduce(auth_ids, {MapSet.new(), memo}, fn auth_id, {acc, memo} ->
                {child_reachable, memo} =
                  reachable_conflicted_ids(auth_id, conflicted_ids, get_event_fn, memo)

                own = if MapSet.member?(conflicted_ids, auth_id), do: [auth_id], else: []

                {acc |> MapSet.union(child_reachable) |> MapSet.union(MapSet.new(own)), memo}
              end)

            {reachable, Map.put(memo, event_id, reachable)}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Reverse topological power ordering
  # ---------------------------------------------------------------------------

  defp reverse_topological_power_ordering(events, auth_diff, get_event_fn) do
    # Build the "mainline": chain of power level events starting from the most
    # recent PL event in auth_diff, following PL events in their auth chains.
    pl_events_in_diff =
      Enum.filter(auth_diff, &(&1["type"] == "m.room.power_levels"))

    mainline = build_mainline(pl_events_in_diff, get_event_fn)

    mainline_index =
      mainline
      |> Enum.with_index()
      |> Map.new(fn {ev, i} -> {ev["event_id"], i} end)

    # Pre-compute mainline position for each event.
    # Mainline position = smallest index in mainline_index that appears in the
    # event's auth chain (including the event itself if it's a PL event).
    get_ml_pos = fn event ->
      chain = [event | auth_chain(event, get_event_fn)]

      chain
      |> Enum.filter(&(&1["type"] == "m.room.power_levels"))
      |> Enum.map(&Map.get(mainline_index, &1["event_id"], length(mainline)))
      |> case do
        [] -> length(mainline)
        positions -> Enum.min(positions)
      end
    end

    # Sort key: power level events come last (is_pl=1 > 0), then by mainline
    # position ascending (lower = closer to current PL = process later but rank
    # first so tied-position events with higher depth win), then depth
    # ascending (so the *higher*-depth, i.e. newer, event of a tied pair
    # sorts last and wins the final Map.put overwrite during replay — verified
    # against spec: ties resolve with the newer event winning), then event_id
    # ascending as the final tie-breaker.
    #
    # Bug fixed here: this used to sort by `-depth` (descending depth),
    # which put the *older* of two tied events last — meaning an ancestor
    # power_levels event pulled into the replay set via auth_diff could
    # overwrite its own newer descendants and "win" a conflict it has no
    # business winning. Latent since this was first written (Phase 12):
    # every conflict test before now used only two-generation fixtures
    # (both candidates direct children of the same root, no third
    # ancestor power event in the replay set), so the bug never
    # triggered. Real multi-generation forks — reachable for the first
    # time now that AxonRoom.StateResolver does genuine DAG replay instead
    # of a one-hop peek — hit it immediately.
    Enum.sort_by(events, fn event ->
      is_pl = if event["type"] == "m.room.power_levels", do: 1, else: 0
      ml_pos = get_ml_pos.(event)
      depth = event["depth"] || 0
      {is_pl, ml_pos, depth, event["event_id"] || ""}
    end)
  end

  defp build_mainline(pl_events, get_event_fn) do
    case Enum.sort_by(pl_events, &(-(&1["depth"] || 0))) do
      [] ->
        []

      [most_recent | _] ->
        build_mainline_chain(
          most_recent,
          get_event_fn,
          [most_recent],
          MapSet.new([most_recent["event_id"]])
        )
    end
  end

  defp build_mainline_chain(event, get_event_fn, acc, visited) do
    next_pl =
      (event["auth_events"] || [])
      |> Enum.find_value(fn auth_id ->
        if MapSet.member?(visited, auth_id) do
          nil
        else
          case get_event_fn.(auth_id) do
            %{"type" => "m.room.power_levels"} = pl -> pl
            _ -> nil
          end
        end
      end)

    case next_pl do
      nil ->
        acc

      pl ->
        build_mainline_chain(pl, get_event_fn, acc ++ [pl], MapSet.put(visited, pl["event_id"]))
    end
  end

  defp state_event?(event), do: Map.has_key?(event, "state_key")
end
