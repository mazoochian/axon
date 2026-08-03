defmodule AxonFederation.RoomLeave do
  @moduledoc """
  Handles the federation room *leave* flow for a user who isn't resident
  in the room locally — the mirror image of `AxonFederation.RoomJoin`.

  The common case: rejecting a federated invite. Axon persists an
  incoming `PUT federation/v2/invite` as a bare membership row (see
  `AxonWeb.FederationController.invite/2`) without ever becoming resident
  (no create event, no full state) — so when that user then calls
  `POST /rooms/:roomId/leave`, there is no local `RoomProcess` to send an
  ordinary leave through (it's never been started for this room, and
  starting one would have nothing but a single membership event to work
  from). The rejection has to go out via `make_leave`/`send_leave`
  against the room's actual resident server instead, exactly like a join.
  """

  require Logger

  alias AxonCore.EventStore
  alias AxonCrypto.{EventHash, KeyServer}
  alias AxonFederation.HttpClient

  @doc """
  Leaves (rejects) a room via federation, trying each server in
  `via_servers` in turn. Returns `:ok` or `{:error, reason}`.
  """
  def leave_via_federation(room_id, user_id, via_servers) do
    Enum.find_value(via_servers, {:error, :all_servers_failed}, fn server ->
      case try_leave(room_id, user_id, server) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Federation leave via #{server} failed: #{inspect(reason)}")
          false
      end
    end)
  end

  defp try_leave(room_id, user_id, server) do
    path = "/_matrix/federation/v1/make_leave/#{URI.encode(room_id)}/#{URI.encode(user_id)}"

    with {:ok, %{"event" => template} = resp} <- HttpClient.get(server, path) do
      room_version = resp["room_version"] || "11"
      signed_event = build_and_sign_leave(template, user_id)

      with {:ok, _} <- send_leave(server, room_id, signed_event) do
        # Direct insert, not RoomProcess — mirrors RoomJoin.import_room_state/4:
        # we're still not resident, just recording our own rejection so it
        # shows up in our own /sync.
        case EventStore.insert_event(signed_event, room_version) do
          {:ok, _} -> :ok
          {:error, :already_exists} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp build_and_sign_leave(template, user_id) do
    leave_event =
      template
      |> Map.put("sender", user_id)
      |> Map.put("state_key", user_id)
      |> Map.update("content", %{"membership" => "leave"}, &Map.put(&1, "membership", "leave"))
      |> Map.put("origin", KeyServer.server_name())
      |> Map.put("origin_server_ts", System.os_time(:millisecond))

    content_hash = EventHash.content_hash(leave_event)
    leave_event = Map.put(leave_event, "hashes", %{"sha256" => content_hash})
    signed = KeyServer.sign_event(leave_event)
    event_id = EventHash.reference_hash(signed)
    Map.put(signed, "event_id", event_id)
  end

  defp send_leave(server, room_id, leave_event) do
    event_id = leave_event["event_id"]
    path = "/_matrix/federation/v2/send_leave/#{URI.encode(room_id)}/#{URI.encode(event_id)}"
    HttpClient.put(server, path, leave_event)
  end
end
