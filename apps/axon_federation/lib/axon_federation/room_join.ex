defmodule AxonFederation.RoomJoin do
  @moduledoc """
  Handles the federation room join flow:
  1. GET /make_join on remote server → partial join event template
  2. Fill in hashes/signatures locally
  3. PUT /send_join/v2 → remote applies and returns full room state
  4. We import the full state and join event into our DB
  """

  require Logger

  alias AxonFederation.{EventVerification, MembershipHandshake}
  alias AxonRoom.{RoomProcess, RoomVersions}

  @doc """
  Joins a remote room for a local user.

  `via_servers` is a list of server names to try the join through.
  Returns {:ok, room_id} or {:error, reason}.
  """
  def join_via_federation(room_id, user_id, via_servers) do
    MembershipHandshake.via_servers(via_servers, "join", &try_join(room_id, user_id, &1))
  end

  defp try_join(room_id, user_id, server) do
    with {:ok, template, room_version} <-
           MembershipHandshake.make(server, "join", room_id, user_id, RoomVersions.supported()),
         join_event =
           MembershipHandshake.sign(template, user_id, %{"membership" => "join"}, room_version),
         {:ok, send_join_resp} <-
           MembershipHandshake.send(
             server,
             "/_matrix/federation/v2/send_join",
             room_id,
             join_event
           ),
         :ok <- import_room_state(send_join_resp, room_id, room_version, join_event) do
      {:ok, room_id}
    end
  end

  # ---------------------------------------------------------------------------
  # Import full room state from send_join response
  # ---------------------------------------------------------------------------

  defp import_room_state(resp, room_id, room_version, join_event) do
    state_events = resp["state"] || []
    auth_chain = resp["auth_chain"] || []

    MembershipHandshake.ensure_room(room_id, room_version, join_event["sender"])

    # Auth chain events first (state events reference them). Keyed by the id
    # each event actually hashes to, never a wire-supplied one (room v3+).
    (auth_chain ++ state_events)
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.put(&1, "event_id", EventVerification.event_id(&1, room_version)))
    |> Enum.uniq_by(& &1["event_id"])
    |> Enum.each(fn event ->
      with {:error, reason} <- MembershipHandshake.insert_event(event, room_version) do
        Logger.warning("Failed to insert event #{event["event_id"]}: #{inspect(reason)}")
      end
    end)

    with {:error, reason} <- MembershipHandshake.insert_event(join_event, room_version) do
      Logger.warning("Failed to insert join event: #{inspect(reason)}")
    end

    # Force the room process to reload from the new state
    RoomProcess.get_or_start(room_id)

    :ok
  end
end
