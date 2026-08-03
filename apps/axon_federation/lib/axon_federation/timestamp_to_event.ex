defmodule AxonFederation.TimestampToEvent do
  @moduledoc """
  Outbound federation half of "jump to date" (MSC3030,
  GET /_matrix/client/v1/rooms/:room_id/timestamp_to_event) — used by
  `AxonWeb.EventController.timestamp_to_event/2` when the local search
  (`AxonCore.EventStore.find_event_by_timestamp/3`) comes up empty. That
  happens whenever this server's own history doesn't reach far enough
  back (or forward) to cover the requested timestamp — most commonly a
  member who joined the room after the target time and was only ever
  handed the room's *current* state, never the older timeline.

  Asks the room's other resident servers, via the server-server
  counterpart of this same endpoint
  (`AxonWeb.FederationController.timestamp_to_event/2`), in turn until one
  gives a usable answer. "Usable" means: the event id it names either
  already exists locally, or can be fetched, signature-verified, and
  stitched into the DAG (`AxonFederation.Backfill.fetch_and_apply_event/3`)
  — per the Server-Server API, a server that learns of an event this way
  "should try to backfill this event" before answering, precisely so a
  client can immediately paginate `/context` or `/messages` around it
  without a separate round trip. A server whose answer fails verification
  is treated the same as one that didn't answer at all — never handed
  back to a client unverified.
  """

  require Logger

  alias AxonCore.EventStore
  alias AxonFederation.{Backfill, HttpClient}

  @doc """
  Queries `room_id`'s other resident servers for the event closest to `ts`
  (ms since the epoch) in `dir` (`"f"`/`"b"`). Returns
  `{:ok, %{event_id: event_id, origin_server_ts: ts}}` for the first
  server that produces one we can verify and store, or `:not_found` if
  there are no other resident servers, none of them have an answer, or
  every answer we got failed verification.
  """
  def find(room_id, ts, dir) do
    room_id
    |> EventStore.remote_servers_for_room()
    |> Enum.find_value(:not_found, fn server ->
      case query_server(room_id, server, ts, dir) do
        {:ok, _result} = ok -> ok
        :error -> nil
      end
    end)
  end

  defp query_server(room_id, server, ts, dir) do
    path = "/_matrix/federation/v1/timestamp_to_event/#{URI.encode(room_id)}?ts=#{ts}&dir=#{dir}"

    case HttpClient.get(server, path) do
      {:ok, %{"event_id" => event_id}} when is_binary(event_id) ->
        case ensure_event_local(room_id, server, event_id) do
          {:ok, origin_server_ts} ->
            {:ok, %{event_id: event_id, origin_server_ts: origin_server_ts}}

          :error ->
            :error
        end

      {:ok, _} ->
        :error

      {:error, reason} ->
        Logger.warning(
          "AxonFederation.TimestampToEvent: #{server} for #{room_id} failed: #{inspect(reason)}"
        )

        :error
    end
  end

  # The remote's claimed origin_server_ts is never trusted as-is — once we
  # hold the event ourselves (whether it was already here or we just
  # fetched it), the timestamp we hand back to the client comes from our
  # own stored copy.
  defp ensure_event_local(room_id, server, event_id) do
    case EventStore.get_event(event_id) do
      {:ok, %{room_id: ^room_id} = event} ->
        {:ok, event.origin_server_ts}

      _ ->
        case Backfill.fetch_and_apply_event(room_id, server, event_id) do
          {:ok, _applied_event_id} ->
            case EventStore.get_event(event_id) do
              {:ok, event} ->
                {:ok, event.origin_server_ts}

              {:error, _} ->
                :error
            end

          {:error, reason} ->
            Logger.warning(
              "AxonFederation.TimestampToEvent: could not fetch/verify #{event_id} " <>
                "from #{server}: #{inspect(reason)}"
            )

            :error
        end
    end
  end
end
