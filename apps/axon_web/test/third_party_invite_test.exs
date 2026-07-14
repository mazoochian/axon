defmodule AxonWeb.ThirdPartyInviteTest do
  @moduledoc """
  Regression tests for Phase 12's third-party (3pid) invite mechanics:
  `m.room.third_party_invite` state events and joining via a signed 3pid
  proof (`AuthRules.valid_third_party_invite?/3`).

  Known, documented gap exercised here only implicitly: axon has no
  identity-server integration, so these tests construct the "signed proof"
  the same way a real identity server would hand it to a client — by
  signing it with this server's own key (the same key embedded in the
  `m.room.third_party_invite` event's `public_key`), since that's the only
  issuer axon can currently vouch for.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonCrypto.KeyServer

  defp signed_3pid_proof(mxid, token) do
    KeyServer.sign_event(%{"mxid" => mxid, "token" => token})
  end

  defp get_state(token, room_id, type, state_key) do
    authed(token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/#{type}/#{state_key}")
  end

  test "creates an m.room.third_party_invite state event with the expected shape" do
    alice = register("3pid_create_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", %{
        "medium" => "email",
        "address" => "bob@example.com"
      })

    assert conn.status == 200

    # No user_id known yet, so no membership row exists for anyone but alice.
    members_conn =
      authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/joined_members")

    assert map_size(decode(members_conn)["joined"]) == 1

    # The state event exists somewhere with a token state_key; find it via
    # a fresh join attempt's error to confirm no shortcut was taken — more
    # directly, sync's initial state should include it.
    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    invite_event = Enum.find(room_state, &(&1["type"] == "m.room.third_party_invite"))

    assert invite_event
    assert invite_event["content"]["display_name"] =~ "***"
    assert is_binary(invite_event["content"]["public_key"])

    assert [%{"public_key" => _, "key_validity_url" => _}] =
             invite_event["content"]["public_keys"]
  end

  test "a member without invite power cannot create a 3pid invite" do
    alice = register("3pid_power_alice_#{System.unique_integer([:positive])}")
    bob = register("3pid_power_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    assert authed(bob.token)
           |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
           |> Map.get(:status) == 200

    conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", %{
        "medium" => "email",
        "address" => "carol@example.com"
      })

    assert conn.status == 403
  end

  test "a validly-signed 3pid proof lets the named mxid join an invite-only room without a direct invite" do
    alice = register("3pid_join_alice_#{System.unique_integer([:positive])}")
    bob = register("3pid_join_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})

    invite_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", %{
        "medium" => "email",
        "address" => "bob@example.com"
      })

    assert invite_conn.status == 200

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    invite_event = Enum.find(room_state, &(&1["type"] == "m.room.third_party_invite"))
    token = invite_event["state_key"]

    proof = signed_3pid_proof(bob.user_id, token)

    join_conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/join/#{room_id}", %{"third_party_signed" => proof})

    assert join_conn.status == 200

    members_conn =
      authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/joined_members")

    assert Map.has_key?(decode(members_conn)["joined"], bob.user_id)
  end

  test "a join is rejected when the signed proof's mxid doesn't match the joining sender" do
    alice = register("3pid_mismatch_alice_#{System.unique_integer([:positive])}")
    bob = register("3pid_mismatch_bob_#{System.unique_integer([:positive])}")
    carol = register("3pid_mismatch_carol_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})

    invite_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", %{
        "medium" => "email",
        "address" => "bob@example.com"
      })

    assert invite_conn.status == 200

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    token = Enum.find(room_state, &(&1["type"] == "m.room.third_party_invite"))["state_key"]

    # Proof was signed for bob, but carol tries to use it.
    proof = signed_3pid_proof(bob.user_id, token)

    join_conn =
      authed(carol.token)
      |> jp("/_matrix/client/v3/join/#{room_id}", %{"third_party_signed" => proof})

    assert join_conn.status == 403
  end

  test "a join is rejected when the proof's signature doesn't verify (bad token)" do
    alice = register("3pid_badsig_alice_#{System.unique_integer([:positive])}")
    bob = register("3pid_badsig_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})

    invite_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", %{
        "medium" => "email",
        "address" => "bob@example.com"
      })

    assert invite_conn.status == 200

    # Sign for a token that doesn't match any real invite event.
    proof = signed_3pid_proof(bob.user_id, "not-a-real-token")

    join_conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/join/#{room_id}", %{"third_party_signed" => proof})

    assert join_conn.status == 403
  end

  test "m.room.third_party_invite state events are visible via the state endpoint" do
    alice = register("3pid_state_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    authed(alice.token)
    |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", %{
      "medium" => "email",
      "address" => "dan@example.com"
    })

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    token = Enum.find(room_state, &(&1["type"] == "m.room.third_party_invite"))["state_key"]

    conn = get_state(alice.token, room_id, "m.room.third_party_invite", token)
    assert conn.status == 200
    assert decode(conn)["public_key"]
  end
end
