defmodule AxonWeb.ThreadsTest do
  @moduledoc """
  GET /_matrix/client/v1/rooms/:room_id/threads — stable spec, formerly
  MSC3856. Thread root events, most-recently-active first, with
  `include=all|participated` filtering and pagination.
  """

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

  defp create_room(token, opts \\ %{}) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", opts)
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp invite(token, room_id, user_id) do
    conn =
      authed(token) |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", %{"user_id" => user_id})

    assert conn.status == 200
  end

  defp join(token, room_id) do
    conn = authed(token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
    assert conn.status == 200
  end

  defp send_event(token, room_id, type, content) do
    txn_id = "txn_#{System.unique_integer([:positive])}"

    conn =
      authed(token) |> jpu("/_matrix/client/v3/rooms/#{room_id}/send/#{type}/#{txn_id}", content)

    assert conn.status == 200
    decode(conn)["event_id"]
  end

  defp send_message(token, room_id, body) do
    send_event(token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => body})
  end

  defp thread_reply(token, room_id, root_id, body) do
    send_event(token, room_id, "m.room.message", %{
      "msgtype" => "m.text",
      "body" => body,
      "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => root_id}
    })
  end

  defp get_threads(token, room_id, query \\ "") do
    path = "/_matrix/client/v1/rooms/#{room_id}/threads"
    path = if query == "", do: path, else: path <> "?" <> query
    authed(token) |> get(path)
  end

  describe "listing thread roots" do
    test "returns an empty chunk, not an error, for a room with no threads" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      send_message(alice.token, room_id, "just a regular message, no threads here")

      conn = get_threads(alice.token, room_id)
      assert conn.status == 200
      body = decode(conn)
      assert body["chunk"] == []
      refute Map.has_key?(body, "next_batch")
    end

    test "lists thread root events, most-recently-active thread first" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      root_a = send_message(alice.token, room_id, "root A")
      root_b = send_message(alice.token, room_id, "root B")
      # A non-thread event in between, shouldn't show up as a root itself.
      send_message(alice.token, room_id, "unrelated message")

      thread_reply(alice.token, room_id, root_a, "reply to A, 1")
      thread_reply(alice.token, room_id, root_b, "reply to B, 1")
      # A later reply to A makes A the more recently active thread, even
      # though its root event was sent first.
      thread_reply(alice.token, room_id, root_a, "reply to A, 2")

      conn = get_threads(alice.token, room_id)
      assert conn.status == 200
      body = decode(conn)

      root_ids = Enum.map(body["chunk"], & &1["event_id"])
      assert root_ids == [root_a, root_b]

      # Regular, non-root messages never appear in the chunk.
      refute Enum.any?(body["chunk"], &(&1["content"]["body"] == "unrelated message"))

      # Each root event carries the usual m.thread relation bundle.
      root_a_entry = Enum.find(body["chunk"], &(&1["event_id"] == root_a))
      thread_bundle = get_in(root_a_entry, ["unsigned", "m.relations", "m.thread"])
      assert thread_bundle["count"] == 2
    end

    test "include=all is the default and includes threads the user never replied to" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      invite(alice.token, room_id, bob.user_id)
      join(bob.token, room_id)

      root_id = send_message(alice.token, room_id, "alice's thread")
      thread_reply(alice.token, room_id, root_id, "alice replies to herself")

      conn = get_threads(bob.token, room_id)
      assert conn.status == 200
      body = decode(conn)
      assert Enum.map(body["chunk"], & &1["event_id"]) == [root_id]

      conn_explicit = get_threads(bob.token, room_id, "include=all")
      assert conn_explicit.status == 200
      assert Enum.map(decode(conn_explicit)["chunk"], & &1["event_id"]) == [root_id]
    end

    test "include=participated only returns threads the user actually replied in" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      invite(alice.token, room_id, bob.user_id)
      join(bob.token, room_id)

      root_alice_only = send_message(alice.token, room_id, "alice-only thread root")
      thread_reply(alice.token, room_id, root_alice_only, "alice replies")

      root_both = send_message(alice.token, room_id, "shared thread root")
      thread_reply(alice.token, room_id, root_both, "alice replies here too")
      thread_reply(bob.token, room_id, root_both, "bob joins in")

      conn = get_threads(bob.token, room_id, "include=participated")
      assert conn.status == 200
      body = decode(conn)

      assert Enum.map(body["chunk"], & &1["event_id"]) == [root_both]
      refute Enum.any?(body["chunk"], &(&1["event_id"] == root_alice_only))

      # Alice, meanwhile, participated in both.
      conn_alice = get_threads(alice.token, room_id, "include=participated")
      alice_root_ids = conn_alice |> decode() |> Map.fetch!("chunk") |> Enum.map(& &1["event_id"])
      assert Enum.sort(alice_root_ids) == Enum.sort([root_alice_only, root_both])
    end

    test "invalid include value is rejected" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      conn = get_threads(alice.token, room_id, "include=bogus")
      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_INVALID_PARAM"
    end

    test "a non-member cannot list threads" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      eve = register("eve_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      root_id = send_message(alice.token, room_id, "root")
      thread_reply(alice.token, room_id, root_id, "reply")

      conn = get_threads(eve.token, room_id)
      assert conn.status == 403
      assert decode(conn)["errcode"] == "M_FORBIDDEN"
    end
  end

  describe "pagination" do
    test "limit + next_batch page through threads without repeats or gaps" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      roots =
        for n <- 1..5 do
          root_id = send_message(alice.token, room_id, "root #{n}")
          thread_reply(alice.token, room_id, root_id, "reply to #{n}")
          root_id
        end

      # Most-recently-active first means reverse creation order here, since
      # each thread got exactly one reply right after its root was created.
      expected_order = Enum.reverse(roots)

      conn1 = get_threads(alice.token, room_id, "limit=2")
      assert conn1.status == 200
      body1 = decode(conn1)
      page1_ids = Enum.map(body1["chunk"], & &1["event_id"])
      assert page1_ids == Enum.take(expected_order, 2)
      assert is_binary(body1["next_batch"])

      conn2 = get_threads(alice.token, room_id, "limit=2&from=#{body1["next_batch"]}")
      assert conn2.status == 200
      body2 = decode(conn2)
      page2_ids = Enum.map(body2["chunk"], & &1["event_id"])
      assert page2_ids == expected_order |> Enum.drop(2) |> Enum.take(2)
      assert is_binary(body2["next_batch"])

      conn3 = get_threads(alice.token, room_id, "limit=2&from=#{body2["next_batch"]}")
      assert conn3.status == 200
      body3 = decode(conn3)
      page3_ids = Enum.map(body3["chunk"], & &1["event_id"])
      assert page3_ids == [List.last(expected_order)]

      # No repeats, no gaps, full coverage across all three pages.
      assert page1_ids ++ page2_ids ++ page3_ids == expected_order

      # A page fetched past the end of the data is the one that finally
      # omits next_batch, matching the existing /relations convention: a
      # non-empty page always carries a next_batch token (even the final
      # partial one), and the client learns pagination is done from the
      # first genuinely empty page.
      conn4 = get_threads(alice.token, room_id, "limit=2&from=#{body3["next_batch"]}")
      assert conn4.status == 200
      body4 = decode(conn4)
      assert body4["chunk"] == []
      refute Map.has_key?(body4, "next_batch")
    end
  end
end
