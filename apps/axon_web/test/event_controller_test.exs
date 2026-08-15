defmodule AxonWeb.EventControllerTest do
  @moduledoc "Tests EventController's redact action (thin/no prior coverage)."

  use AxonWeb.ConnCase, async: false

  defp register(username) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/register",
        Jason.encode!(%{
          "username" => username,
          "password" => "Test1234!",
          "kind" => "user",
          "auth" => %{"type" => "m.login.dummy"}
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    %{token: body["access_token"], user_id: body["user_id"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp jp(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp jpu(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token, opts \\ %{"preset" => "public_chat"}) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", opts)
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp send_message(token, room_id) do
    txn = "txn_#{System.unique_integer([:positive])}"

    conn =
      authed(token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn}", %{"body" => "hi"})

    assert conn.status == 200
    decode(conn)["event_id"]
  end

  defp get_event(token, room_id, event_id) do
    authed(token) |> get("/_matrix/client/v3/rooms/#{room_id}/event/#{URI.encode(event_id)}")
  end

  test "a user can redact their own event, and its content is stripped" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id = send_message(alice.token, room_id)

    txn = "txn_#{System.unique_integer([:positive])}"

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{
        "reason" => "oops"
      })

    assert conn.status == 200
    assert is_binary(decode(conn)["event_id"])

    after_conn = get_event(alice.token, room_id, event_id)
    assert decode(after_conn)["content"] == %{}
  end

  test "a moderator with redact power can redact another user's event, stripping its content" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    event_id = send_message(bob.token, room_id)

    txn = "txn_#{System.unique_integer([:positive])}"

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{})

    assert conn.status == 200

    after_conn = get_event(alice.token, room_id, event_id)
    assert decode(after_conn)["content"] == %{}
  end

  # Per spec (13.2 "Redactions"), the redaction event itself is *always*
  # accepted regardless of the sender's power — whether it actually
  # applies (strips the target's content) is a separate, server-local
  # policy: only the target's original sender or someone with the room's
  # "redact" power level (default 50). A user with neither still gets a
  # 200 for the redaction event, but the target's content survives.
  test "a user without redact power cannot strip another user's event content" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    charlie = register("charlie_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    authed(charlie.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    event_id = send_message(bob.token, room_id)

    txn = "txn_#{System.unique_integer([:positive])}"

    conn =
      authed(charlie.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{})

    assert conn.status == 200

    after_conn = get_event(alice.token, room_id, event_id)
    assert decode(after_conn)["content"] == %{"body" => "hi"}
  end

  # Regression: get_messages/2, get_state/2, and get_state_event/2 had no
  # membership check at all (get_state/get_state_event) or only checked
  # "forgotten" (get_messages) — meaning any authenticated user on the
  # server could read a private room's full timeline/state just by knowing
  # its room_id, never having been a member. get_relations/2 already had
  # the correct nil-membership check; the fix mirrors it.
  test "a stranger who was never a member cannot read messages, state, or a specific state event of a private room" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    stranger = register("stranger_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})
    send_message(alice.token, room_id)

    messages_conn = authed(stranger.token) |> get("/_matrix/client/v3/rooms/#{room_id}/messages")
    assert messages_conn.status == 403

    state_conn = authed(stranger.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state")
    assert state_conn.status == 403

    state_event_conn =
      authed(stranger.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.create/")

    assert state_event_conn.status == 403
  end

  test "a current member CAN read messages, state, and a specific state event" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})
    send_message(alice.token, room_id)

    assert authed(alice.token)
           |> get("/_matrix/client/v3/rooms/#{room_id}/messages")
           |> Map.get(:status) == 200

    assert authed(alice.token)
           |> get("/_matrix/client/v3/rooms/#{room_id}/state")
           |> Map.get(:status) == 200

    conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.create/")
    assert conn.status == 200
  end

  test "redact is idempotent per txn_id" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id = send_message(alice.token, room_id)
    txn = "txn_#{System.unique_integer([:positive])}"

    conn1 =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{})

    conn2 =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{})

    assert decode(conn1)["event_id"] == decode(conn2)["event_id"]
  end

  # GET /rooms/:room_id/context/:event_id — previously unimplemented (no
  # route at all, so it 404'd generically); found by Complement's
  # TestMSC4291RoomIDAsHashOfCreateEvent_RoomIDIsOnCreateEvent, which
  # reads the create event back through this endpoint among others.
  describe "get_context/2" do
    test "returns the target event with surrounding timeline and room state" do
      alice = register("ctx_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      ids = for _ <- 1..5, do: send_message(alice.token, room_id)
      target = Enum.at(ids, 2)

      conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/context/#{URI.encode(target)}?limit=4")

      assert conn.status == 200
      body = decode(conn)

      assert body["event"]["event_id"] == target
      assert body["event"]["room_id"] == room_id

      before_ids = Enum.map(body["events_before"], & &1["event_id"])
      after_ids = Enum.map(body["events_after"], & &1["event_id"])

      # events_before is reverse-chronological, events_after chronological,
      # and neither includes the target itself.
      refute target in before_ids
      refute target in after_ids
      assert Enum.at(ids, 1) in before_ids
      assert Enum.at(ids, 3) in after_ids

      state_types = Enum.map(body["state"], & &1["type"])
      assert "m.room.create" in state_types
      assert is_binary(body["start"]) and is_binary(body["end"])
    end

    test "404s for an event that doesn't exist, or belongs to another room" do
      alice = register("ctx_missing_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)
      other_room = create_room(alice.token)
      other_event = send_message(alice.token, other_room)

      missing =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/context/%24nope")

      assert missing.status == 404

      wrong_room =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/context/#{URI.encode(other_event)}")

      assert wrong_room.status == 404
    end

    test "403s for a non-member" do
      alice = register("ctx_owner_#{System.unique_integer([:positive])}")
      mallory = register("ctx_outsider_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "private_chat"})
      event_id = send_message(alice.token, room_id)

      conn =
        authed(mallory.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/context/#{URI.encode(event_id)}")

      assert conn.status == 403
    end
  end
end
