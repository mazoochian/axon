defmodule AxonFederation.MembershipHandshake do
  @moduledoc """
  The `make_*`/`send_*` handshake shared by `AxonFederation.RoomJoin`,
  `AxonFederation.RoomKnock` and `AxonFederation.RoomLeave`: fetch a
  membership template from a resident server, validate it, sign it as our
  user, and PUT it back.
  """

  require Logger

  alias AxonCore.{EventStore, Repo}
  alias AxonCrypto.{EventHash, KeyServer}
  alias AxonFederation.HttpClient
  alias AxonRoom.RoomVersions

  @doc """
  Calls `attempt` with each server in turn until one doesn't return
  `{:error, _}`; `{:error, :all_servers_failed}` when none succeed.
  """
  def via_servers(servers, action, attempt) do
    Enum.find_value(servers, {:error, :all_servers_failed}, fn server ->
      case attempt.(server) do
        {:error, reason} ->
          Logger.warning("Federation #{action} via #{server} failed: #{inspect(reason)}")
          false

        result ->
          result
      end
    end)
  end

  @doc """
  `GET make_<membership>` for `user_id`, advertising `versions` (if any).
  Returns `{:ok, template, room_version}` once the template is validated.
  """
  def make(server, membership, room_id, user_id, versions \\ []) do
    query = Enum.map_join(versions, "&", &"ver=#{&1}")

    path =
      "/_matrix/federation/v1/make_#{membership}/#{URI.encode(room_id)}/#{URI.encode(user_id)}" <>
        if(query == "", do: "", else: "?" <> query)

    with {:ok, resp} <- HttpClient.get(server, path) do
      validate_template(resp, room_id, user_id)
    end
  end

  # A make_* response without room_version is treated as room version 11.
  defp validate_template(%{"event" => %{} = template} = resp, room_id, user_id) do
    room_version = resp["room_version"] || "11"

    cond do
      template["type"] != "m.room.member" -> {:error, :invalid_template}
      template["room_id"] != room_id -> {:error, :invalid_template}
      template["state_key"] not in [nil, user_id] -> {:error, :invalid_template}
      not is_map(Map.get(template, "content", %{})) -> {:error, :invalid_template}
      not RoomVersions.supported?(room_version) -> {:error, :unsupported_room_version}
      true -> {:ok, template, room_version}
    end
  end

  defp validate_template(_resp, _room_id, _user_id), do: {:error, :invalid_template}

  @doc """
  Fills in `template` as `user_id`'s own event, merging `content` over the
  template's (so resident-server additions such as
  `join_authorised_via_users_server` survive), then hashes and signs it.
  """
  def sign(template, user_id, content, room_version) do
    event =
      template
      |> Map.put("sender", user_id)
      |> Map.put("state_key", user_id)
      |> Map.update("content", content, &Map.merge(&1, content))
      |> Map.put("origin", KeyServer.server_name())
      |> Map.put("origin_server_ts", System.os_time(:millisecond))

    signed =
      event
      |> Map.put("hashes", %{"sha256" => EventHash.content_hash(event)})
      |> KeyServer.sign_event(room_version)

    Map.put(signed, "event_id", EventHash.reference_hash(signed, room_version))
  end

  @doc "PUTs a signed membership event to `<endpoint>/<room_id>/<event_id>`."
  def send(server, endpoint, room_id, event) do
    path = "#{endpoint}/#{URI.encode(room_id)}/#{URI.encode(event["event_id"])}"
    HttpClient.put(server, path, event)
  end

  @doc "Ensures a local `rooms` row exists for a room we aren't (yet) resident in."
  def ensure_room(room_id, room_version, creator) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "rooms",
      [
        %{
          room_id: room_id,
          version: room_version,
          creator: creator,
          is_public: false,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    :ok
  end

  @doc "Stores an event (an already-stored one is success). Returns `:ok` or `{:error, reason}`."
  def insert_event(event, room_version) do
    with {:ok, _} <- EventStore.insert_event(event, room_version), do: :ok
  end
end
