defmodule AxonWeb.DirectoryControllerTest do
  @moduledoc "Tests the public room directory and room alias CRUD."

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

  # URI.encode/1 deliberately leaves "#" unescaped (it's valid in a path),
  # but here it starts the path segment itself — an unescaped "#" gets
  # parsed as a fragment delimiter and truncates the request before the
  # router ever sees it.
  defp encode_alias(room_alias), do: room_alias |> URI.encode() |> String.replace("#", "%23")

  describe "publicRooms" do
    test "lists a room published to the directory" do
      alice = register("alice_#{System.unique_integer([:positive])}")

      room_id =
        create_room(alice.token, %{
          "preset" => "public_chat",
          "name" => "Public Room",
          "visibility" => "public"
        })

      conn = authed(alice.token) |> get("/_matrix/client/v3/publicRooms")
      assert conn.status == 200
      body = decode(conn)
      assert Enum.any?(body["chunk"], &(&1["room_id"] == room_id))
    end

    test "a private room is not listed" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "private_chat"})

      conn = authed(alice.token) |> get("/_matrix/client/v3/publicRooms")
      body = decode(conn)
      refute Enum.any?(body["chunk"], &(&1["room_id"] == room_id))
    end

    test "search filter matches on room name" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      unique = "Zorblaxx#{System.unique_integer([:positive])}"

      room_id =
        create_room(alice.token, %{
          "preset" => "public_chat",
          "name" => unique,
          "visibility" => "public"
        })

      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/publicRooms", %{"filter" => %{"generic_search_term" => unique}})

      body = decode(conn)
      assert Enum.any?(body["chunk"], &(&1["room_id"] == room_id))
    end

    test "num_joined_members reflects actual membership count" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat", "visibility" => "public"})

      conn = authed(alice.token) |> get("/_matrix/client/v3/publicRooms")
      entry = Enum.find(decode(conn)["chunk"], &(&1["room_id"] == room_id))
      assert entry["num_joined_members"] == 1
    end
  end

  describe "set_room_visibility" do
    test "toggling visibility to public makes the room appear in publicRooms" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "private_chat"})

      conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/directory/list/room/#{room_id}", %{"visibility" => "public"})

      assert conn.status == 200

      list_conn = authed(alice.token) |> get("/_matrix/client/v3/publicRooms")
      assert Enum.any?(decode(list_conn)["chunk"], &(&1["room_id"] == room_id))
    end
  end

  describe "alias CRUD" do
    test "put_alias then get_alias round-trips the room_id" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{})
      room_alias = "#testalias#{System.unique_integer([:positive])}:localhost"

      put_conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/directory/room/#{encode_alias(room_alias)}", %{
          "room_id" => room_id
        })

      assert put_conn.status == 200

      get_conn =
        build_conn() |> get("/_matrix/client/v3/directory/room/#{encode_alias(room_alias)}")

      assert get_conn.status == 200
      assert decode(get_conn)["room_id"] == room_id
    end

    test "put_alias without room_id is a missing param error" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_alias = "#noroomid#{System.unique_integer([:positive])}:localhost"

      conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/directory/room/#{encode_alias(room_alias)}", %{})

      assert conn.status == 400
    end

    test "get_alias for an unknown alias 404s" do
      conn = build_conn() |> get("/_matrix/client/v3/directory/room/%23nonexistent:localhost")
      assert conn.status == 404
    end

    test "list_room_aliases requires membership" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{})

      conn = authed(bob.token) |> get("/_matrix/client/v3/rooms/#{room_id}/aliases")
      assert conn.status == 403
    end

    test "list_room_aliases returns aliases for a joined member" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{})
      room_alias = "#listtest#{System.unique_integer([:positive])}:localhost"

      authed(alice.token)
      |> jpu("/_matrix/client/v3/directory/room/#{encode_alias(room_alias)}", %{
        "room_id" => room_id
      })

      conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/aliases")
      assert conn.status == 200
      assert room_alias in decode(conn)["aliases"]
    end

    test "the alias creator can delete their own alias" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{})
      room_alias = "#deletetest#{System.unique_integer([:positive])}:localhost"

      authed(alice.token)
      |> jpu("/_matrix/client/v3/directory/room/#{encode_alias(room_alias)}", %{
        "room_id" => room_id
      })

      del_conn =
        authed(alice.token)
        |> delete("/_matrix/client/v3/directory/room/#{encode_alias(room_alias)}")

      assert del_conn.status == 200

      get_conn =
        build_conn() |> get("/_matrix/client/v3/directory/room/#{encode_alias(room_alias)}")

      assert get_conn.status == 404
    end

    test "a non-creator without sufficient power cannot delete another's alias" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{preset: "public_chat"})
      room_alias = "#protectedalias#{System.unique_integer([:positive])}:localhost"

      authed(alice.token)
      |> jpu("/_matrix/client/v3/directory/room/#{encode_alias(room_alias)}", %{
        "room_id" => room_id
      })

      authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})

      del_conn =
        authed(bob.token)
        |> delete("/_matrix/client/v3/directory/room/#{encode_alias(room_alias)}")

      assert del_conn.status == 403
    end

    test "deleting an unknown alias 404s" do
      alice = register("alice_#{System.unique_integer([:positive])}")

      conn =
        authed(alice.token)
        |> delete("/_matrix/client/v3/directory/room/%23doesnotexist:localhost")

      assert conn.status == 404
    end
  end
end
