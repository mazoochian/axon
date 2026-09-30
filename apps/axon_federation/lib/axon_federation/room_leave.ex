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

  alias AxonFederation.MembershipHandshake

  @doc """
  Leaves (rejects) a room via federation, trying each server in
  `via_servers` in turn. Returns `:ok` or `{:error, reason}`.
  """
  def leave_via_federation(room_id, user_id, via_servers) do
    MembershipHandshake.via_servers(via_servers, "leave", &try_leave(room_id, user_id, &1))
  end

  defp try_leave(room_id, user_id, server) do
    with {:ok, template, room_version} <-
           MembershipHandshake.make(server, "leave", room_id, user_id),
         leave_event =
           MembershipHandshake.sign(template, user_id, %{"membership" => "leave"}, room_version),
         {:ok, _} <-
           MembershipHandshake.send(
             server,
             "/_matrix/federation/v2/send_leave",
             room_id,
             leave_event
           ) do
      # Direct insert, not RoomProcess — mirrors RoomJoin.import_room_state/4:
      # we're still not resident, just recording our own rejection so it
      # shows up in our own /sync.
      MembershipHandshake.insert_event(leave_event, room_version)
    end
  end
end
