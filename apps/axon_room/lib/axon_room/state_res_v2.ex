defmodule AxonRoom.StateResV2 do
  @moduledoc """
  Matrix State Resolution v2, plus the room-v12 (MSC4297 "state resolution
  v2.1") tweak to it: iterative auth checks start from an empty state map
  instead of the unconflicted state map (unconflicted is merged back in only
  once, at the very end — see `resolve/3`'s `room_version` branch below).

  Not implemented: MSC4297's "conflicted state subgraph"/"auth difference
  over the full conflicted set" refinement, which only changes the outcome
  for deep, multi-generation DAG forks. `AxonRoom.StateResolver` (this
  module's only caller) already deliberately resolves just enough state for
  one incoming PDU's auth check rather than replaying arbitrary historical
  forks, so that refinement wouldn't be reachable through the current call
  path anyway — documented there too.

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

    {unconflicted, conflicted_events} =
      Enum.reduce(all_keys, {%{}, MapSet.new()}, fn key, {unc, conf} ->
        events =
          state_sets
          |> Enum.map(&Map.get(&1, key))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(& &1["event_id"])

        case events do
          [] -> {unc, conf}
          [single] -> {Map.put(unc, key, single), conf}
          many -> {unc, Enum.reduce(many, conf, &MapSet.put(&2, &1))}
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

      full_conflicted = conflicted_list ++ auth_diff

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
    # first so tied-position events with higher depth win), then depth descending,
    # then event_id ascending as tie-breaker.
    Enum.sort_by(events, fn event ->
      is_pl = if event["type"] == "m.room.power_levels", do: 1, else: 0
      ml_pos = get_ml_pos.(event)
      depth = event["depth"] || 0
      {is_pl, ml_pos, -depth, event["event_id"] || ""}
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
