defmodule AxonWeb.FederationFanoutTest do
  @moduledoc """
  Regression test for Phase 2 federation fan-out: an inbound federation PDU
  applied via `AxonRoom.RoomProcess.apply_remote_event/2` must update the
  room's live in-memory state (not just the DB) and must notify local
  `/sync` long-pollers via PubSub, the same as a locally-sent event does.

  Previously `federation_controller.ex` wrote inbound PDUs straight to
  `EventStore.insert_event/2`, bypassing the room's GenServer entirely: no
  broadcast, and the in-memory `current_state` used for local auth checks
  went stale until the next snapshot reload.
  """

  use AxonWeb.ConnCase, async: false

  alias AxonRoom.RoomProcess

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

  defp authed(token) do
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end

  defp jp(conn, path, body) do
    conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", %{})
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  test "apply_remote_event updates live room state and broadcasts to local /sync" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)

    Phoenix.PubSub.subscribe(Axon.PubSub, "room:#{room_id}")

    {prev_last_event_id, prev_depth} = RoomProcess.get_position(room_id)

    pdu = %{
      "event_id" => "$remote_#{System.unique_integer([:positive])}:remote.example",
      "room_id" => room_id,
      "sender" => alice.user_id,
      "type" => "m.room.message",
      "content" => %{"msgtype" => "m.text", "body" => "hello from federation"},
      "origin" => "remote.example",
      "origin_server_ts" => System.os_time(:millisecond),
      "prev_events" => [prev_last_event_id],
      "auth_events" => [],
      "depth" => prev_depth + 1,
      "signatures" => %{},
      "hashes" => %{}
    }

    assert {:ok, event_id} = RoomProcess.apply_remote_event(room_id, pdu)
    assert event_id == pdu["event_id"]

    # In-memory state must advance (not just the DB row).
    assert {^event_id, new_depth} = RoomProcess.get_position(room_id)
    assert new_depth == prev_depth + 1

    # Local /sync long-pollers must be woken up immediately.
    assert_receive {:new_event, ^room_id, %{"event_id" => ^event_id}}, 1000
  end
end
