defmodule AxonFederation.RoomJoin do
  @moduledoc """
  Handles the federation room join flow:
  1. GET /make_join on remote server → partial join event template
  2. Fill in hashes/signatures locally
  3. PUT /send_join/v2 → remote applies and returns full room state
  4. We import the full state and join event into our DB
  """

  require Logger

  alias AxonCore.{EventStore, Repo}
  alias AxonCrypto.{EventHash, KeyServer}
  alias AxonFederation.HttpClient
  alias AxonRoom.RoomProcess

  @supported_versions ~w(2 3 4 5 6 7 8 9 10 11)

  @doc """
  Joins a remote room for a local user.

  `via_servers` is a list of server names to try the join through.
  Returns {:ok, room_id} or {:error, reason}.
  """
  def join_via_federation(room_id, user_id, via_servers) do
    version_query = Enum.map_join(@supported_versions, "&", &"ver=#{&1}")

    Enum.find_value(via_servers, {:error, :all_servers_failed}, fn server ->
      case try_join(room_id, user_id, server, version_query) do
        {:ok, result} -> {:ok, result}
        {:error, reason} ->
          Logger.warning("Federation join via #{server} failed: #{inspect(reason)}")
          false
      end
    end)
  end

  defp try_join(room_id, user_id, server, version_query) do
    path = "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(user_id)}?#{version_query}"

    with {:ok, make_join_resp} <- HttpClient.get(server, path),
         {:ok, template, room_version} <- extract_template(make_join_resp),
         {:ok, join_event} <- build_and_sign_join(template, user_id),
         {:ok, send_join_resp} <- send_join(server, room_id, join_event),
         :ok <- import_room_state(send_join_resp, room_id, user_id, room_version, join_event) do
      {:ok, room_id}
    end
  end

  defp extract_template(%{"event" => template, "room_version" => version}) do
    {:ok, template, version}
  end
  defp extract_template(%{"event" => template}), do: {:ok, template, "11"}
  defp extract_template(_), do: {:error, :invalid_make_join_response}

  defp build_and_sign_join(template, user_id) do
    # Fill in required fields that we control
    join_event =
      template
      |> Map.put("sender", user_id)
      |> Map.put("state_key", user_id)
      |> Map.put("content", %{"membership" => "join"})
      |> Map.put("origin", KeyServer.server_name())
      |> Map.put("origin_server_ts", System.os_time(:millisecond))

    # Compute content hash + reference hash (event_id) + sign
    content_hash = EventHash.content_hash(join_event)
    join_event = Map.put(join_event, "hashes", %{"sha256" => content_hash})
    signed = KeyServer.sign_event(join_event)
    event_id = EventHash.reference_hash(signed)
    {:ok, Map.put(signed, "event_id", event_id)}
  end

  defp send_join(server, room_id, join_event) do
    event_id = join_event["event_id"]
    path = "/_matrix/federation/v2/send_join/#{URI.encode(room_id)}/#{URI.encode(event_id)}"
    HttpClient.put(server, path, join_event)
  end

  # ---------------------------------------------------------------------------
  # Import full room state from send_join response
  # ---------------------------------------------------------------------------

  defp import_room_state(resp, room_id, _user_id, room_version, join_event) do
    state_events = resp["state"] || []
    auth_chain = resp["auth_chain"] || []

    # Create or verify room exists locally
    Repo.insert_all("rooms", [
      %{
        room_id: room_id,
        version: room_version,
        creator: join_event["sender"],
        is_public: false,
        created_at: DateTime.utc_now(:microsecond)
      }
    ], on_conflict: :nothing)

    # Store all auth chain events first (they are referenced by state events)
    all_events = (auth_chain ++ state_events) |> Enum.uniq_by(& &1["event_id"])

    Enum.each(all_events, fn event ->
      case EventStore.insert_event(event, room_version) do
        {:ok, _} -> :ok
        {:error, :already_exists} -> :ok
        {:error, reason} ->
          Logger.warning("Failed to insert event #{event["event_id"]}: #{inspect(reason)}")
      end
    end)

    # Store the join event itself
    case EventStore.insert_event(join_event, room_version) do
      {:ok, _} -> :ok
      {:error, :already_exists} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to insert join event: #{inspect(reason)}")
    end

    # Force the room process to reload from the new state
    RoomProcess.get_or_start(room_id)

    :ok
  end
end
