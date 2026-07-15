defmodule AxonWeb.E2E.GuestAccessFlowTest do
  @moduledoc """
  End-to-end guest access flow chaining pieces that are each unit-tested
  individually (guest registration, guest_access join gating) but never
  exercised together: a guest is rejected from a room whose
  m.room.guest_access is "forbidden" (the default), can join one that's
  "can_join", and can then use the rest of the client API exactly like a
  full user (send messages, sync) — axon's guest model gates ONLY room
  join, nothing else, which is worth pinning down explicitly since it's
  narrower than what the Matrix spec envisions for guests.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  test "a guest is rejected by a forbidden-guest-access room but admitted by a can_join room, then behaves like a full member" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    guest = register_guest()
    assert String.starts_with?(guest.user_id, "@guest_")

    private_room = create_room(alice.token, %{"preset" => "private_chat"})
    public_room = create_room(alice.token, %{"preset" => "public_chat"})

    # --- default guest_access ("forbidden") rejects the guest ---
    forbidden_conn = authed(guest.token) |> jp("/_matrix/client/v3/join/#{private_room}", %{})
    assert forbidden_conn.status == 403

    # --- public_chat's guest_access ("can_join") admits the guest ---
    join_conn = authed(guest.token) |> jp("/_matrix/client/v3/join/#{public_room}", %{})
    assert join_conn.status == 200

    members_conn =
      authed(alice.token) |> get("/_matrix/client/v3/rooms/#{public_room}/joined_members")

    assert Map.has_key?(decode(members_conn)["joined"], guest.user_id)

    # --- once admitted, the guest is otherwise indistinguishable from a full user ---
    event_id =
      send_event(guest.token, public_room, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "hi, I'm a guest"
      })

    sync_conn = authed(guest.token) |> get("/_matrix/client/v3/sync")
    assert sync_conn.status == 200

    timeline_events =
      get_in(decode(sync_conn), ["rooms", "join", public_room, "timeline", "events"]) || []

    assert Enum.any?(timeline_events, &(&1["event_id"] == event_id))

    # a guest can even create their own room — axon does not restrict this
    guest_room = create_room(guest.token, %{"preset" => "public_chat"})
    assert is_binary(guest_room)
  end

  test "an invited guest can accept the invite even when guest_access is forbidden" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    guest = register_guest()
    room_id = create_room(alice.token, %{"preset" => "private_chat"})

    invite_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", %{"user_id" => guest.user_id})

    assert invite_conn.status == 200

    accept_conn = authed(guest.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    assert accept_conn.status == 200
  end
end
