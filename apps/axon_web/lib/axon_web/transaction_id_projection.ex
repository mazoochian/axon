defmodule AxonWeb.TransactionIdProjection do
  @moduledoc false

  import Ecto.Query, only: [from: 2]
  alias AxonCore.Repo

  # Each public entry point describes a protocol response envelope. Content maps
  # are deliberately opaque: only actual event slots and the two specified
  # bundled-relation event slots are traversed.
  def project(response, user_id, device_id), do: project_envelope(response, user_id, device_id)

  def project_many(events, user_id, device_id),
    do: project_events(events, user_id, device_id)

  def project_sync_rooms(rooms, user_id, device_id) do
    paths =
      for membership <- ["join", "leave"],
          {room_id, room} <- Map.get(rooms, membership, %{}),
          reduce: [] do
        acc -> [{membership, room_id, room} | acc]
      end

    events =
      Enum.flat_map(paths, fn {_, _, room} ->
        (get_in(room, ["timeline", "events"]) || []) ++
          (get_in(room, ["state", "events"]) || [])
      end)

    txns = load_transactions(event_ids(events), user_id, device_id)

    Enum.reduce(paths, rooms, fn {membership, room_id, room}, acc ->
      timeline = room["timeline"] || %{}
      state = room["state"] || %{}

      projected_timeline =
        Map.put(timeline, "events", project_event_list(timeline["events"] || [], txns))

      projected_state = Map.put(state, "events", project_event_list(state["events"] || [], txns))

      projected_room =
        room
        |> Map.put("timeline", projected_timeline)
        |> Map.put("state", projected_state)

      put_in(acc, [membership, room_id], projected_room)
    end)
  end

  defp project_envelope(%{"event_id" => _} = event, user_id, device_id),
    do: project_events(event, user_id, device_id)

  defp project_envelope(response, user_id, device_id) do
    slots = ["chunk", "state", "events_before", "events_after"]

    events =
      Enum.flat_map(slots, fn key -> List.wrap(response[key]) end) ++ List.wrap(response["event"])

    txns = load_transactions(event_ids(events), user_id, device_id)

    response
    |> update_list_slots(slots, txns)
    |> update_event_slot("event", txns)
  end

  defp project_events(events, user_id, device_id) do
    txns = load_transactions(event_ids(List.wrap(events)), user_id, device_id)
    if is_list(events), do: project_event_list(events, txns), else: project_event(events, txns)
  end

  defp event_ids(events) do
    events
    |> Enum.flat_map(fn event ->
      [event_id(event) | bundled_events(event) |> Enum.map(&event_id/1)]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp load_transactions([], _user_id, _device_id), do: %{}

  defp load_transactions(event_ids, user_id, device_id) do
    Repo.all(
      from(t in "client_txns",
        where: t.user_id == ^user_id and t.device_id == ^device_id and t.event_id in ^event_ids,
        select: {t.event_id, t.txn_id}
      )
    )
    |> Map.new()
  end

  defp project_event_list(events, txns), do: Enum.map(events, &project_event(&1, txns))

  defp project_event(%{"event_id" => id} = event, txns) do
    event = project_bundled(event, txns)

    case txns[id] do
      nil -> event
      txn -> Map.put(event, "unsigned", Map.put(event["unsigned"] || %{}, "transaction_id", txn))
    end
  end

  defp project_event(value, _txns), do: value

  defp bundled_events(event) do
    relations = get_in(event, ["unsigned", "m.relations"]) || %{}

    Enum.flat_map(relations, fn
      {"m.replace", %{"event_id" => _} = replacement} -> [replacement]
      {_type, %{"latest_event" => %{"event_id" => _} = latest}} -> [latest]
      _ -> []
    end)
  end

  defp project_bundled(event, txns) do
    case get_in(event, ["unsigned", "m.relations"]) do
      relations when is_map(relations) ->
        projected =
          Map.new(relations, fn
            {"m.replace", %{"event_id" => _} = replacement} ->
              {"m.replace", project_event(replacement, txns)}

            {type, %{"latest_event" => %{"event_id" => _} = latest} = bundle} ->
              {type, Map.put(bundle, "latest_event", project_event(latest, txns))}

            pair ->
              pair
          end)

        put_in(event, ["unsigned", "m.relations"], projected)

      _ ->
        event
    end
  end

  defp event_id(%{"event_id" => id}) when is_binary(id), do: id
  defp event_id(_), do: nil

  defp update_list_slots(response, keys, txns),
    do:
      Enum.reduce(keys, response, fn key, acc ->
        if is_list(acc[key]), do: Map.put(acc, key, project_event_list(acc[key], txns)), else: acc
      end)

  defp update_event_slot(response, key, txns),
    do:
      if(is_map(response[key]),
        do: Map.put(response, key, project_event(response[key], txns)),
        else: response
      )
end
