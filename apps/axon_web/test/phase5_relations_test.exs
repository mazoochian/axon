defmodule AxonWeb.Phase5RelationsTest do
  @moduledoc """
  Phase 5 (Advanced Stable Features) — reactions, threads, spaces hierarchy.
  """

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

  defp create_room(token, opts \\ %{}) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", opts)
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp send_event(token, room_id, type, content) do
    txn_id = "txn_#{System.unique_integer([:positive])}"
    conn = authed(token) |> jpu("/_matrix/client/v3/rooms/#{room_id}/send/#{type}/#{txn_id}", content)
    assert conn.status == 200
    decode(conn)["event_id"]
  end

  defp send_state(token, room_id, type, state_key, content) do
    conn = authed(token) |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/#{type}/#{state_key}", content)
    assert conn.status == 200
    decode(conn)["event_id"]
  end

  defp get_event(token, room_id, event_id) do
    conn = authed(token) |> get("/_matrix/client/v3/rooms/#{room_id}/event/#{event_id}")
    assert conn.status == 200
    decode(conn)
  end

  describe "reactions (m.annotation aggregation)" do
    test "get_event bundles unsigned.m.relations.m.annotation with counts" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      msg_id = send_event(alice.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "hi"})

      send_event(alice.token, room_id, "m.reaction", %{
        "m.relates_to" => %{"rel_type" => "m.annotation", "event_id" => msg_id, "key" => "👍"}
      })
      send_event(alice.token, room_id, "m.reaction", %{
        "m.relates_to" => %{"rel_type" => "m.annotation", "event_id" => msg_id, "key" => "👍"}
      })
      send_event(alice.token, room_id, "m.reaction", %{
        "m.relates_to" => %{"rel_type" => "m.annotation", "event_id" => msg_id, "key" => "🎉"}
      })

      event = get_event(alice.token, room_id, msg_id)
      chunk = get_in(event, ["unsigned", "m.relations", "m.annotation", "chunk"])

      assert %{"type" => "m.reaction", "key" => "👍", "count" => 2} in chunk
      assert %{"type" => "m.reaction", "key" => "🎉", "count" => 1} in chunk
    end

    test "GET /relations/:eventId returns the reaction events" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      msg_id = send_event(alice.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "hi"})

      reaction_id =
        send_event(alice.token, room_id, "m.reaction", %{
          "m.relates_to" => %{"rel_type" => "m.annotation", "event_id" => msg_id, "key" => "👍"}
        })

      conn = authed(alice.token) |> get("/_matrix/client/v1/rooms/#{room_id}/relations/#{msg_id}")
      assert conn.status == 200
      body = decode(conn)

      assert Enum.any?(body["chunk"], &(&1["event_id"] == reaction_id))
    end
  end

  describe "threads (m.thread bundling)" do
    test "get_event bundles unsigned.m.relations.m.thread with latest_event and count" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      root_id = send_event(alice.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "root"})

      send_event(alice.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "reply 1",
        "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => root_id}
      })

      reply2_id =
        send_event(alice.token, room_id, "m.room.message", %{
          "msgtype" => "m.text",
          "body" => "reply 2",
          "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => root_id}
        })

      event = get_event(alice.token, room_id, root_id)
      thread = get_in(event, ["unsigned", "m.relations", "m.thread"])

      assert thread["count"] == 2
      assert thread["latest_event"]["event_id"] == reply2_id
      assert thread["current_user_participated"] == true
    end
  end

  describe "spaces (/hierarchy)" do
    test "walks m.space.child links and returns room summaries" do
      alice = register("alice_#{System.unique_integer([:positive])}")

      space_id =
        create_room(alice.token, %{
          "creation_content" => %{"type" => "m.space"},
          "name" => "My Space"
        })

      child_id = create_room(alice.token, %{"name" => "Child Room"})

      send_state(alice.token, space_id, "m.space.child", child_id, %{"via" => ["localhost"]})

      conn = authed(alice.token) |> get("/_matrix/client/v1/rooms/#{space_id}/hierarchy")
      assert conn.status == 200
      body = decode(conn)

      room_ids = Enum.map(body["rooms"], & &1["room_id"])
      assert space_id in room_ids
      assert child_id in room_ids

      space_entry = Enum.find(body["rooms"], &(&1["room_id"] == space_id))
      assert Enum.any?(space_entry["children_state"], &(&1["state_key"] == child_id))
    end
  end
end
