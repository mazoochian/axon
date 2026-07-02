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

  Scope: this resolves *just enough* state to run the auth check for one
  incoming PDU — the state set built from each prev_event's own
  `auth_events` (which, by construction, already point at the specific
  create/power_levels/join_rules/member events that authorized *that*
  branch — exactly the granularity `AxonRoom.AuthRules` looks at) plus our
  own current view, fed through `AxonRoom.StateResV2.resolve/2`. It does
  not reconstruct arbitrary historical room state or replace the room's
  authoritative `current_state` — that would require tracking state per
  DAG branch, a bigger architectural change than fits here. Deep backfill
  / multi-generation forks are a known remaining gap (see plan doc).
  """

  alias AxonCore.EventStore
  alias AxonRoom.StateResV2

  @doc "Whether `pdu` forks away from `last_event_id` and needs resolution before auth-checking."
  def needs_resolution?(pdu, last_event_id) do
    case pdu["prev_events"] || [] do
      [] -> false
      [^last_event_id] -> false
      _ -> true
    end
  end

  @doc """
  Builds the state set to auth-check `pdu` against: resolves the state
  implied by each of `pdu`'s prev_events (via their auth_events) together
  with `current_state`, our own view.
  """
  def resolve_for_auth_check(pdu, current_state) do
    prev_events = pdu["prev_events"] || []

    branch_state_sets =
      prev_events
      |> Enum.map(&state_set_from_auth_events/1)
      |> Enum.reject(&(&1 == %{}))

    state_sets = [current_state | branch_state_sets] |> Enum.uniq()

    resolved = StateResV2.resolve(state_sets, &EventStore.get_event_map/1)
    Map.merge(current_state, resolved)
  end

  defp state_set_from_auth_events(event_id) do
    case EventStore.get_event_map(event_id) do
      nil ->
        %{}

      event ->
        (event["auth_events"] || [])
        |> Enum.map(&EventStore.get_event_map/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&Map.has_key?(&1, "state_key"))
        |> Map.new(fn ae -> {{ae["type"], ae["state_key"]}, ae} end)
    end
  end
end
