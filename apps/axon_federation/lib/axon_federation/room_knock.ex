defmodule AxonFederation.RoomKnock do
  @moduledoc """
  Handles the federation room knock flow (MSC2403), mirroring `RoomJoin`:
  1. GET /make_knock on remote server → partial knock event template
  2. Fill in hashes/signatures (and reason) locally
  3. PUT /send_knock → remote applies and returns a stripped room preview
  4. We record our own "knock" membership plus the returned preview, so
     /sync can show the user something for a room they haven't joined yet.
  """

  require Logger

  alias AxonCore.{EventStore, Repo}
  alias AxonCrypto.{EventHash, KeyServer}
  alias AxonFederation.HttpClient

  @supported_versions ~w(7 8 9 10 11)

  @doc """
  Knocks on a remote room for a local user. `via_servers` is a list of
  server names to try. Returns {:ok, room_id} or {:error, reason}.
  """
  def knock_via_federation(room_id, user_id, via_servers, reason) do
    version_query = Enum.map_join(@supported_versions, "&", &"ver=#{&1}")

    Enum.find_value(via_servers, {:error, :all_servers_failed}, fn server ->
      case try_knock(room_id, user_id, server, version_query, reason) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          Logger.warning("Federation knock via #{server} failed: #{inspect(reason)}")
          false
      end
    end)
  end

  defp try_knock(room_id, user_id, server, version_query, reason) do
    path =
      "/_matrix/federation/v1/make_knock/#{URI.encode(room_id)}/#{URI.encode(user_id)}?#{version_query}"

    with {:ok, make_knock_resp} <- HttpClient.get(server, path),
         {:ok, template, room_version} <- extract_template(make_knock_resp),
         {:ok, knock_event} <- build_and_sign_knock(template, user_id, reason),
         {:ok, send_knock_resp} <- send_knock(server, room_id, knock_event),
         :ok <- import_knock(send_knock_resp, room_id, room_version, knock_event) do
      {:ok, room_id}
    end
  end

  defp extract_template(%{"event" => template, "room_version" => version}),
    do: {:ok, template, version}

  defp extract_template(%{"event" => template}), do: {:ok, template, "11"}
  defp extract_template(_), do: {:error, :invalid_make_knock_response}

  defp build_and_sign_knock(template, user_id, reason) do
    extra_content =
      if reason,
        do: %{"membership" => "knock", "reason" => reason},
        else: %{"membership" => "knock"}

    knock_event =
      template
      |> Map.put("sender", user_id)
      |> Map.put("state_key", user_id)
      |> Map.update("content", extra_content, &Map.merge(&1, extra_content))
      |> Map.put("origin", KeyServer.server_name())
      |> Map.put("origin_server_ts", System.os_time(:millisecond))

    content_hash = EventHash.content_hash(knock_event)
    knock_event = Map.put(knock_event, "hashes", %{"sha256" => content_hash})
    signed = KeyServer.sign_event(knock_event)
    event_id = EventHash.reference_hash(signed)
    {:ok, Map.put(signed, "event_id", event_id)}
  end

  defp send_knock(server, room_id, knock_event) do
    event_id = knock_event["event_id"]
    path = "/_matrix/federation/v1/send_knock/#{URI.encode(room_id)}/#{URI.encode(event_id)}"
    HttpClient.put(server, path, knock_event)
  end

  defp import_knock(resp, room_id, room_version, knock_event) do
    knock_room_state = resp["knock_room_state"] || []
    user_id = knock_event["sender"]

    # Ensure the room row exists locally (FK target for the events table) —
    # we may have no other state for this room at all yet.
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "rooms",
      [
        %{
          room_id: room_id,
          version: room_version,
          creator: user_id,
          is_public: false,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    case EventStore.insert_event(knock_event, room_version) do
      {:ok, _} -> :ok
      {:error, :already_exists} -> :ok
      {:error, reason} -> Logger.warning("Failed to insert knock event: #{inspect(reason)}")
    end

    EventStore.set_knock_preview_state(room_id, user_id, knock_room_state)
    :ok
  end
end
