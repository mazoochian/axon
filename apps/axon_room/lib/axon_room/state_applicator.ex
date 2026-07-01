defmodule AxonRoom.StateApplicator do
  @moduledoc """
  Applies an event to an in-memory state map.

  State map: %{{type, state_key} => event_wire_map}
  Non-state events (no state_key) do not change the state map.
  """

  @doc "Returns updated state map after applying the event."
  def apply(%{"state_key" => state_key} = event, state) when is_binary(state_key) do
    Map.put(state, {event["type"], state_key}, event)
  end

  def apply(_event, state), do: state
end
