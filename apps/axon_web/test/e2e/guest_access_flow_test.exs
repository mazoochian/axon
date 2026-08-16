defmodule AxonWeb.E2E.GuestAccessFlowTest do
  @moduledoc """
  End-to-end guest access flow chaining pieces that are each unit-tested
  individually (guest registration, guest_access join gating) but never
  exercised together: a guest is rejected from a room whose
  m.room.guest_access is "forbidden", can join one that's "can_join", and
  can then use the rest of the client API exactly like a full user (send
  messages, sync) — axon's guest model gates ONLY room join, nothing else,
  which is worth pinning down explicitly since it's narrower than what the
  Matrix spec envisions for guests.

  Per the createRoom preset table, `public_chat` is guest_can_join=false
  and both private presets are guest_can_join=true — the one preset where
  guests are *not* welcomed by default is the public one.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  test "a guest is rejected by a forbidden-guest-access room but admitted by a can_join room, then behaves like a full member" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    guest = register_guest()
    assert String.starts_with?(guest.user_id, "@guest_")

    # Both rooms are public_chat (join_rule "public", so a bare join isn't
    # gated by that first) — join_rule and guest_access are independent
    # gates, and private_chat's join_rule ("invite") would 403 *any*
    # non-invited join, guest or not, before guest_access is even
    # consulted. Isolating guest_access as the one variable means
    # overriding it explicitly via initial_state rather than relying on
    # a preset default for the admitting room.
    forbidden_room = create_room(alice.token, %{"preset" => "public_chat"})

    admitting_room =
      create_room(alice.token, %{
        "preset" => "public_chat",
        "initial_state" => [
          %{"type" => "m.room.guest_access", "content" => %{"guest_access" => "can_join"}}
        ]
      })

    # --- default guest_access ("forbidden") rejects the guest ---
    forbidden_conn = authed(guest.token) |> jp("/_matrix/client/v3/join/#{forbidden_room}", %{})
    assert forbidden_conn.status == 403

    # --- explicit guest_access ("can_join") admits the guest ---
    join_conn = authed(guest.token) |> jp("/_matrix/client/v3/join/#{admitting_room}", %{})
    assert join_conn.status == 200

    members_conn =
      authed(alice.token) |> get("/_matrix/client/v3/rooms/#{admitting_room}/joined_members")

    assert Map.has_key?(decode(members_conn)["joined"], guest.user_id)

    # --- once admitted, the guest is otherwise indistinguishable from a full user ---
    event_id =
      send_event(guest.token, admitting_room, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "hi, I'm a guest"
      })

    sync_conn = authed(guest.token) |> get("/_matrix/client/v3/sync")
    assert sync_conn.status == 200

    timeline_events =
      get_in(decode(sync_conn), ["rooms", "join", admitting_room, "timeline", "events"]) || []

    assert Enum.any?(timeline_events, &(&1["event_id"] == event_id))

    # a guest can even create their own room — axon does not restrict this
    guest_room = create_room(guest.token, %{"preset" => "public_chat"})
    assert is_binary(guest_room)
  end

  test "an invited guest can accept the invite even when guest_access is forbidden" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    guest = register_guest()
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    invite_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", %{"user_id" => guest.user_id})

    assert invite_conn.status == 200

    accept_conn = authed(guest.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    assert accept_conn.status == 200
  end
end
