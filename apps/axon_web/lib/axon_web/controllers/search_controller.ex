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

  @default_limit 10
  @default_context_limit 5

  def search(conn, params) do
    user_id = conn.assigns.current_user_id
    room_events = get_in(params, ["search_categories", "room_events"])
    search_term = room_events && room_events["search_term"]

    if is_nil(search_term) or search_term == "" do
      conn
      |> put_status(400)
      |> json(%{
        "errcode" => "M_MISSING_PARAM",
        "error" => "search_categories.room_events.search_term is required"
      })
    else
      order_by = if room_events["order_by"] == "recent", do: "recent", else: "rank"
      limit = get_in(room_events, ["event_context", "limit"]) || @default_limit

      before_limit =
        get_in(room_events, ["event_context", "before_limit"]) || @default_context_limit

      after_limit =
        get_in(room_events, ["event_context", "after_limit"]) || @default_context_limit

      requested_rooms = get_in(room_events, ["filter", "rooms"])

      joined_rooms = EventStore.get_joined_rooms(user_id)

      search_rooms =
        if requested_rooms,
          do: Enum.filter(joined_rooms, &(&1 in requested_rooms)),
          else: joined_rooms

      {ranked_ids, count} = EventStore.search_messages(search_rooms, search_term, order_by, limit)
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

      json(conn, %{
        "search_categories" => %{
          "room_events" => %{
            "count" => count,
            "results" => results,
            "highlights" => search_term |> String.split() |> Enum.uniq()
          }
        }
      })
    end
  end

  defp build_context(event, before_limit, after_limit) do
    events_before =
      EventStore.get_messages(event.room_id, event.stream_ordering, "b", before_limit)
      |> Enum.reverse()
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
