defmodule AxonWeb.EventControllerTest do
  @moduledoc "Tests EventController's redact action (thin/no prior coverage)."

  use AxonWeb.ConnCase, async: false

  defp register(username) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/_matrix/client/v3/register", Jason.encode!(%{
        "username" => username,
        "password" => "Test1234!",
        "kind" => "user",
        "auth" => %{"type" => "m.login.dummy"}
      }))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    %{token: body["access_token"], user_id: body["user_id"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
  defp jp(conn, path, body), do: conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))
  defp jpu(conn, path, body), do: conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token, opts \\ %{"preset" => "public_chat"}) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", opts)
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp send_message(token, room_id) do
    txn = "txn_#{System.unique_integer([:positive])}"
    conn = authed(token) |> jpu("/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn}", %{"body" => "hi"})
    assert conn.status == 200
    decode(conn)["event_id"]
  end

  test "a user can redact their own event" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id = send_message(alice.token, room_id)

    txn = "txn_#{System.unique_integer([:positive])}"
    conn = authed(alice.token) |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{"reason" => "oops"})
    assert conn.status == 200
    assert is_binary(decode(conn)["event_id"])
  end

  test "a moderator with redact power can redact another user's event" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    event_id = send_message(bob.token, room_id)

    txn = "txn_#{System.unique_integer([:positive])}"
    conn = authed(alice.token) |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{})
    assert conn.status == 200
  end

  # KNOWN GAP (documented, not fixed here — see plan's fix-small-flag-big
  # policy): AxonRoom.AuthRules has no dedicated rule for m.room.redaction.
  # It falls through to the generic non-state-event check, which only
  # compares against events_default/events["m.room.redaction"] (unset, so
  # events_default — normally 0) and never consults the room's "redact"
  # power level at all. Per spec, redacting your OWN event should always be
  # allowed, but redacting someone ELSE's event should require power >=
  # "redact" (default 50) — currently ANY joined user can redact ANY other
  # user's event. A correct fix needs AuthRules to know who sent the
  # target event (via its "redacts" reference), which means either giving
  # the currently-pure AuthRules module DB access or moving this check
  # elsewhere — an architectural decision, not a one-line fix, so this is
  # flagged as a finding rather than patched here.
  test "a user without redact power CAN currently redact another's event (documents the gap above)" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    charlie = register("charlie_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    authed(charlie.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    event_id = send_message(bob.token, room_id)

    txn = "txn_#{System.unique_integer([:positive])}"
    conn = authed(charlie.token) |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{})
    assert conn.status == 200
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

    state_event_conn = authed(stranger.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.create/")
    assert state_event_conn.status == 403
  end

  test "a current member CAN read messages, state, and a specific state event" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})
    send_message(alice.token, room_id)

    assert authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/messages") |> Map.get(:status) == 200
    assert authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state") |> Map.get(:status) == 200

    conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.create/")
    assert conn.status == 200
  end

  test "redact is idempotent per txn_id" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id = send_message(alice.token, room_id)
    txn = "txn_#{System.unique_integer([:positive])}"

    conn1 = authed(alice.token) |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{})
    conn2 = authed(alice.token) |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{})

    assert decode(conn1)["event_id"] == decode(conn2)["event_id"]
  end
end
