defmodule AxonCore.PowerLevels do
  @moduledoc """
  Effective power levels computed from a room's state map
  (`%{{type, state_key} => event_map}`, as returned by
  `AxonCore.EventStore.get_current_state_map/1`).

  Room v12+ creators (the create event's sender plus any
  `additional_creators`) have infinite power (MSC4289). In earlier versions,
  while no `m.room.power_levels` event exists, the creator has level 100.
  Room versions 1–9 permit levels encoded as strings of integers.
  """

  # Strictly greater than the largest canonical-JSON integer (2^53 - 1).
  @infinite_power 1_000_000_000_000_000_000

  @doc "The `m.room.power_levels` content, or `%{}` when the room has none."
  def content(state) do
    case state[{"m.room.power_levels", ""}] do
      %{"content" => %{} = content} -> content
      _ -> %{}
    end
  end

  @doc "The room's creators: one pre-v12, the sender plus `additional_creators` from v12."
  def creators(state, version) do
    case state[{"m.room.create", ""}] do
      %{} = create ->
        content = if is_map(create["content"]), do: create["content"], else: %{}
        primary = create["sender"] || content["creator"]

        additional =
          case content["additional_creators"] do
            ids when is_list(ids) -> if privileged_creators?(version), do: ids, else: []
            _ -> []
          end

        for id <- [primary | additional], is_binary(id), into: MapSet.new(), do: id

      _ ->
        MapSet.new()
    end
  end

  @doc "`user_id`'s effective power level in the room described by `state`."
  def user_level(state, user_id, version) do
    creator? = MapSet.member?(creators(state, version), user_id)

    cond do
      creator? and privileged_creators?(version) ->
        @infinite_power

      creator? and not Map.has_key?(state, {"m.room.power_levels", ""}) ->
        100

      true ->
        pl = content(state)
        users = if is_map(pl["users"]), do: pl["users"], else: %{}
        to_int(users[user_id]) || to_int(pl["users_default"]) || 0
    end
  end

  @doc "The level required for `action` (`\"redact\"`, `\"kick\"`, `\"invite\"`, ...)."
  def required_level(state, action) do
    to_int(content(state)[action]) || default_level(action)
  end

  defp default_level("invite"), do: 0
  defp default_level(_action), do: 50

  defp privileged_creators?(version) do
    case Integer.parse(to_string(version)) do
      {n, ""} -> n >= 12
      _ -> false
    end
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
