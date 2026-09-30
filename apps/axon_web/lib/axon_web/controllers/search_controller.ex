defmodule AxonWeb.SearchController do
  @moduledoc """
  POST /_matrix/client/v3/search — full-text search over message bodies,
  scoped to rooms the requester is joined to (or `filter.rooms`, intersected
  with that same set — no cross-room leakage regardless of what's asked for).
  """

  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  plug(AxonWeb.Plug.RateLimit, [bucket: :search, key_by: :user] when action == :search)

  alias AxonCore.EventStore
  alias AxonWeb.Params
  import AxonCore.MapUtil, only: [maybe_put: 3]

  @default_limit 10
  @default_context_limit 5

  def search(conn, params) do
    case validate(params["search_categories"]) do
      {:ok, room_events, filter} ->
        do_search(conn, params, room_events, filter)

      {:error, errcode, message} ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => errcode, "error" => message})
    end
  end

  defp validate(%{"room_events" => %{} = room_events}) do
    filter = room_events["filter"] || %{}
    rooms = is_map(filter) && filter["rooms"]

    cond do
      not is_binary(room_events["search_term"]) or room_events["search_term"] == "" ->
        missing_search_term()

      not is_map(filter) ->
        {:error, "M_BAD_JSON", "search_categories.room_events.filter must be an object"}

      not (is_nil(rooms) or (is_list(rooms) and Enum.all?(rooms, &is_binary/1))) ->
        {:error, "M_BAD_JSON", "filter.rooms must be a list of room IDs"}

      true ->
        {:ok, room_events, filter}
    end
  end

  defp validate(%{"room_events" => nil}), do: missing_search_term()

  defp validate(%{"room_events" => _}),
    do: {:error, "M_BAD_JSON", "search_categories.room_events must be an object"}

  defp validate(_search_categories), do: missing_search_term()

  defp missing_search_term,
    do: {:error, "M_MISSING_PARAM", "search_categories.room_events.search_term is required"}

  defp do_search(conn, params, room_events, filter) do
    user_id = conn.assigns.current_user_id
    search_term = room_events["search_term"]
    order_by = if room_events["order_by"] == "recent", do: "recent", else: "rank"
    limit = Params.int(filter["limit"], @default_limit, 1, 100)
    offset = parse_offset(params["next_batch"])

    event_context =
      if is_map(room_events["event_context"]), do: room_events["event_context"], else: %{}

    before_limit = Params.int(event_context["before_limit"], @default_context_limit, 0, 100)
    after_limit = Params.int(event_context["after_limit"], @default_context_limit, 0, 100)
    requested_rooms = filter["rooms"]

    joined_rooms = EventStore.get_joined_rooms(user_id)

    search_rooms =
      if requested_rooms,
        do: Enum.filter(joined_rooms, &(&1 in requested_rooms)),
        else: joined_rooms

    {ranked_ids, count, next_offset} =
      EventStore.search_messages(search_rooms, search_term, order_by, limit, offset)

    rank_by_id = Map.new(ranked_ids)

    results =
      ranked_ids
      |> Enum.map(fn {event_id, _rank} -> EventStore.get_event(event_id) end)
      |> Enum.flat_map(fn
        {:ok, event} -> [event]
        _ -> []
      end)
      |> Enum.map(fn event ->
        %{
          "rank" => Map.get(rank_by_id, event.event_id),
          "result" => EventStore.event_to_map(event),
          "context" => build_context(event, before_limit, after_limit)
        }
      end)

    room_events_response =
      %{
        "count" => count,
        "results" => results,
        "highlights" => search_term |> String.split() |> Enum.uniq()
      }
      |> maybe_put("next_batch", next_offset && Integer.to_string(next_offset))

    json(conn, %{"search_categories" => %{"room_events" => room_events_response}})
  end

  defp parse_offset(nil), do: 0

  defp parse_offset(next_batch) do
    case Integer.parse(next_batch) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end

  defp build_context(event, before_limit, after_limit) do
    # Per spec, events_before is reverse-chronological (closest-to-the-result
    # first) — get_messages(..., "b", ...) already returns that order
    # natively, so no re-sort is needed (or wanted: reversing it here was
    # backwards from what the spec, and Complement's TestSearch, expect).
    events_before =
      EventStore.get_messages(event.room_id, event.stream_ordering, "b", before_limit)
      |> Enum.map(&EventStore.event_to_map/1)

    events_after =
      EventStore.get_messages(event.room_id, event.stream_ordering, "f", after_limit)
      |> Enum.map(&EventStore.event_to_map/1)

    %{
      "events_before" => events_before,
      "events_after" => events_after,
      "start" => Integer.to_string(event.stream_ordering - 1),
      "end" => Integer.to_string(event.stream_ordering + 1)
    }
  end
end
