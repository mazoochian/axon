defmodule AxonWeb.RoomControllerTest do
  @moduledoc """
  Tests `RoomController` actions with thin/no prior coverage: kick, ban,
  unban, knock, members, joined_members, typing. (create/join already get
  substantial indirect coverage via the `create_room`/`register` helpers
  used throughout the rest of the suite.)
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

  defp create_room(token, opts) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", opts)
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp join(token, room_id) do
    conn = authed(token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    assert conn.status == 200
  end

  describe "kick" do
    test "a joined member with kick power can kick another joined member" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)

      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/kick", %{
          "user_id" => bob.user_id,
          "reason" => "spamming"
        })

      assert conn.status == 200

      members_conn =
        authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/members?membership=leave")

      assert Enum.any?(decode(members_conn)["chunk"], &(&1["state_key"] == bob.user_id))
    end

    test "a member without kick power cannot kick another" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      charlie = register("charlie_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)
      join(charlie.token, room_id)

      conn =
        authed(bob.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/kick", %{"user_id" => charlie.user_id})

      assert conn.status in [400, 403]
    end
  end

  describe "ban / unban" do
    test "banning a member removes them and prevents rejoin, unban allows rejoin" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)

      ban_conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/ban", %{
          "user_id" => bob.user_id,
          "reason" => "rule violation"
        })

      assert ban_conn.status == 200

      rejoin_conn = authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
      assert rejoin_conn.status == 403

      unban_conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/unban", %{"user_id" => bob.user_id})

      assert unban_conn.status == 200

      rejoin_conn2 = authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
      assert rejoin_conn2.status == 200
    end
  end

  describe "knock" do
    test "knocking on a knock-enabled room succeeds and shows a preview" do
      alice = register("alice_#{System.unique_integer([:positive])}")

      room_id =
        create_room(alice.token, %{
          "name" => "Knockable Room",
          "initial_state" => [
            %{"type" => "m.room.join_rules", "content" => %{"join_rule" => "knock"}}
          ]
        })

      bob = register("bob_#{System.unique_integer([:positive])}")

      conn =
        authed(bob.token)
        |> jp("/_matrix/client/v3/knock/#{room_id}", %{"reason" => "let me in please"})

      assert conn.status == 200
      assert decode(conn)["room_id"] == room_id
    end

    test "knocking on a non-knockable room is rejected" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "private_chat"})

      bob = register("bob_#{System.unique_integer([:positive])}")
      conn = authed(bob.token) |> jp("/_matrix/client/v3/knock/#{room_id}", %{})
      assert conn.status in [400, 403]
    end
  end

  describe "members / joined_members" do
    test "members lists all membership states by default" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)

      conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/members")
      state_keys = decode(conn)["chunk"] |> Enum.map(& &1["state_key"])
      assert alice.user_id in state_keys
      assert bob.user_id in state_keys
    end

    test "members can be filtered by membership state" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)

      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/kick", %{"user_id" => bob.user_id})

      conn =
        authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/members?membership=join")

      state_keys = decode(conn)["chunk"] |> Enum.map(& &1["state_key"])
      assert alice.user_id in state_keys
      refute bob.user_id in state_keys
    end

    test "joined_members requires the requester to be joined" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "private_chat"})

      conn = authed(bob.token) |> get("/_matrix/client/v3/rooms/#{room_id}/joined_members")
      assert conn.status == 403
    end

    test "joined_members returns display info for current members" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/joined_members")
      assert conn.status == 200
      assert Map.has_key?(decode(conn)["joined"], alice.user_id)
    end
  end

  describe "typing" do
    test "PUT typing always returns an empty ack (stub, not persisted)" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{})

      conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/rooms/#{room_id}/typing/#{alice.user_id}", %{
          "typing" => true,
          "timeout" => 30_000
        })

      assert conn.status == 200
      assert decode(conn) == %{}
    end
  end

  describe "forget" do
    test "cannot forget a room you're still joined to" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{})

      conn = authed(alice.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/forget", %{})
      assert conn.status == 400
    end

    test "can forget a room after leaving" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      bob = register("bob_#{System.unique_integer([:positive])}")
      join(bob.token, room_id)
      authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/leave", %{})

      conn = authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/forget", %{})
      assert conn.status == 200
    end
  end
end
