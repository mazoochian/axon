defmodule AxonWeb.SpaceControllerTest do
  @moduledoc """
  Extends `phase5_relations_test.exs`'s basic hierarchy happy path with
  nesting, `suggested_only` filtering, and access control.
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

  defp add_child(token, space_id, child_id, extra_content \\ %{}) do
    content = Map.merge(%{"via" => ["localhost"]}, extra_content)

    conn =
      authed(token)
      |> jpu("/_matrix/client/v3/rooms/#{space_id}/state/m.space.child/#{child_id}", content)

    assert conn.status == 200
  end

  test "walks a nested space hierarchy two levels deep" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    top = create_room(alice.token, %{"preset" => "public_chat", "name" => "Top Space"})
    mid = create_room(alice.token, %{"preset" => "public_chat", "name" => "Mid Space"})
    leaf = create_room(alice.token, %{"preset" => "public_chat", "name" => "Leaf Room"})

    add_child(alice.token, top, mid)
    add_child(alice.token, mid, leaf)

    conn = authed(alice.token) |> get("/_matrix/client/v1/rooms/#{top}/hierarchy")
    assert conn.status == 200
    room_ids = decode(conn)["rooms"] |> Enum.map(& &1["room_id"])
    assert top in room_ids
    assert mid in room_ids
    assert leaf in room_ids
  end

  test "suggested_only excludes children not marked suggested" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    top = create_room(alice.token, %{"preset" => "public_chat"})
    suggested_child = create_room(alice.token, %{"preset" => "public_chat"})
    plain_child = create_room(alice.token, %{"preset" => "public_chat"})

    add_child(alice.token, top, suggested_child, %{"suggested" => true})
    add_child(alice.token, top, plain_child, %{"suggested" => false})

    conn =
      authed(alice.token) |> get("/_matrix/client/v1/rooms/#{top}/hierarchy?suggested_only=true")

    room_ids = decode(conn)["rooms"] |> Enum.map(& &1["room_id"])
    assert suggested_child in room_ids
    refute plain_child in room_ids
  end

  test "max_depth limits how far the walk descends" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    top = create_room(alice.token, %{"preset" => "public_chat"})
    mid = create_room(alice.token, %{"preset" => "public_chat"})
    leaf = create_room(alice.token, %{"preset" => "public_chat"})
    add_child(alice.token, top, mid)
    add_child(alice.token, mid, leaf)

    conn = authed(alice.token) |> get("/_matrix/client/v1/rooms/#{top}/hierarchy?max_depth=0")
    room_ids = decode(conn)["rooms"] |> Enum.map(& &1["room_id"])
    assert top in room_ids
    refute mid in room_ids
    refute leaf in room_ids
  end

  test "a private child room the requester can't access is excluded from the walk" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    top = create_room(alice.token, %{"preset" => "public_chat"})
    private_child = create_room(alice.token, %{"preset" => "private_chat"})
    add_child(alice.token, top, private_child)

    conn = authed(bob.token) |> get("/_matrix/client/v1/rooms/#{top}/hierarchy")
    assert conn.status == 200
    room_ids = decode(conn)["rooms"] |> Enum.map(& &1["room_id"])
    assert top in room_ids
    refute private_child in room_ids
  end

  test "hierarchy on an inaccessible/nonexistent room 404s" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v1/rooms/!nonexistent:localhost/hierarchy")
    assert conn.status == 404
  end
end
