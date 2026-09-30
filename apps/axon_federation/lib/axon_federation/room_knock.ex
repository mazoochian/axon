defmodule AxonFederation.RoomKnock do
  @moduledoc """
  Handles the federation room knock flow (MSC2403), mirroring `RoomJoin`:
  1. GET /make_knock on remote server → partial knock event template
  2. Fill in hashes/signatures (and reason) locally
  3. PUT /send_knock → remote applies and returns a stripped room preview
  4. We record our own "knock" membership plus the returned preview, so
     /sync can show the user something for a room they haven't joined yet.
  """

  alias AxonCore.EventStore
  alias AxonFederation.MembershipHandshake
  alias AxonRoom.RoomVersions

  require Logger

  @doc """
  Knocks on a remote room for a local user. `via_servers` is a list of
  server names to try. Returns {:ok, room_id} or {:error, reason}.
  """
  def knock_via_federation(room_id, user_id, via_servers, reason) do
    MembershipHandshake.via_servers(
      via_servers,
      "knock",
      &try_knock(room_id, user_id, &1, reason)
    )
  end

  defp try_knock(room_id, user_id, server, reason) do
    content =
      if reason,
        do: %{"membership" => "knock", "reason" => reason},
        else: %{"membership" => "knock"}

    with {:ok, template, room_version} <-
           MembershipHandshake.make(server, "knock", room_id, user_id, knock_versions()),
         knock_event = MembershipHandshake.sign(template, user_id, content, room_version),
         {:ok, send_knock_resp} <-
           MembershipHandshake.send(
             server,
             "/_matrix/federation/v1/send_knock",
             room_id,
             knock_event
           ) do
      import_knock(send_knock_resp, room_id, room_version, knock_event)
      {:ok, room_id}
    end
  end

  # Knocking was introduced in room version 7.
  defp knock_versions, do: Enum.filter(RoomVersions.supported(), &RoomVersions.at_least?(&1, 7))

  defp import_knock(resp, room_id, room_version, knock_event) do
    user_id = knock_event["sender"]

    # The rooms row is the FK target for the events table — we may have no
    # other state for this room at all yet.
    MembershipHandshake.ensure_room(room_id, room_version, user_id)

    with {:error, reason} <- MembershipHandshake.insert_event(knock_event, room_version) do
      Logger.warning("Failed to insert knock event: #{inspect(reason)}")
    end

    EventStore.set_knock_preview_state(room_id, user_id, resp["knock_room_state"] || [])
  end
end
