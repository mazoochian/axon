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

  defp space(token, name) do
    create_room(token, %{
      "preset" => "public_chat",
      "name" => name,
      "creation_content" => %{"type" => "m.space"}
    })
  end

  test "walks a nested space hierarchy two levels deep" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    top = space(alice.token, "Top Space")
    mid = space(alice.token, "Mid Space")
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
    top = space(alice.token, "Top")
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
    top = space(alice.token, "Top")
    mid = space(alice.token, "Mid")
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
    top = space(alice.token, "Top")
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

  test "does not recurse through an ordinary (non-space) room's children" do
    # Mirrors Complement's TestClientSpacesSummary: a plain room can carry an
    # m.space.child link (nothing stops a client from sending one), but per
    # MSC2946 the server must only walk children of rooms whose own
    # room_type is m.space. R2 -> R5 here should be silently ignored.
    alice = register("alice_#{System.unique_integer([:positive])}")
    top = space(alice.token, "Top")
    plain_room = create_room(alice.token, %{"preset" => "public_chat", "name" => "R2"})
    grandchild = create_room(alice.token, %{"preset" => "public_chat", "name" => "R5"})

    add_child(alice.token, top, plain_room)
    add_child(alice.token, plain_room, grandchild)

    conn = authed(alice.token) |> get("/_matrix/client/v1/rooms/#{top}/hierarchy")
    assert conn.status == 200
    room_ids = decode(conn)["rooms"] |> Enum.map(& &1["room_id"])
    assert top in room_ids
    assert plain_room in room_ids
    refute grandchild in room_ids
  end

  test "hierarchy entries carry the full per-room summary field set" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    top =
      create_room(alice.token, %{
        "preset" => "public_chat",
        "name" => "Top",
        "topic" => "A topic",
        "creation_content" => %{"type" => "m.space"}
      })

    conn = authed(alice.token) |> get("/_matrix/client/v1/rooms/#{top}/hierarchy")
    assert conn.status == 200
    [entry] = decode(conn)["rooms"]

    assert entry["room_id"] == top
    assert entry["name"] == "Top"
    assert entry["topic"] == "A topic"
    assert entry["room_type"] == "m.space"
    assert entry["join_rule"] == "public"
    assert is_integer(entry["num_joined_members"])
    assert is_boolean(entry["world_readable"])
    assert is_boolean(entry["guest_can_join"])
    assert is_binary(entry["room_version"])
    assert entry["children_state"] == []
  end

  test "allowed_room_ids is surfaced for a restricted room and omitted for a non-restricted one" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    top = space(alice.token, "Top")

    restricted_room =
      create_room(alice.token, %{
        "preset" => "public_chat",
        "room_version" => "8",
        "initial_state" => [
          %{
            "type" => "m.room.join_rules",
            "state_key" => "",
            "content" => %{
              "join_rule" => "restricted",
              "allow" => [%{"type" => "m.room_membership", "room_id" => top}]
            }
          }
        ]
      })

    invite_room = create_room(alice.token, %{"preset" => "private_chat"})

    add_child(alice.token, top, restricted_room)
    add_child(alice.token, top, invite_room)

    conn = authed(alice.token) |> get("/_matrix/client/v1/rooms/#{top}/hierarchy")
    assert conn.status == 200
    rooms = decode(conn)["rooms"]

    restricted_entry = Enum.find(rooms, &(&1["room_id"] == restricted_room))
    assert restricted_entry["join_rule"] == "restricted"
    assert restricted_entry["allowed_room_ids"] == [top]

    # invite_room is visible to alice (she created it, so she's joined) but
    # has an ordinary "invite" join_rule — allowed_room_ids must be absent.
    invite_entry = Enum.find(rooms, &(&1["room_id"] == invite_room))
    refute Map.has_key?(invite_entry, "allowed_room_ids")
  end

  test "a restricted child room becomes visible once the requester joins the allow-listed space" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")

    top =
      create_room(alice.token, %{
        "preset" => "public_chat",
        "name" => "Top",
        "creation_content" => %{"type" => "m.space"},
        "initial_state" => [
          %{
            "type" => "m.room.history_visibility",
            "state_key" => "",
            "content" => %{"history_visibility" => "world_readable"}
          }
        ]
      })

    restricted_room =
      create_room(alice.token, %{
        "preset" => "public_chat",
        "room_version" => "8",
        "initial_state" => [
          %{
            "type" => "m.room.join_rules",
            "state_key" => "",
            "content" => %{
              "join_rule" => "restricted",
              "allow" => [%{"type" => "m.room_membership", "room_id" => top}]
            }
          }
        ]
      })

    add_child(alice.token, top, restricted_room)

    conn = authed(bob.token) |> get("/_matrix/client/v1/rooms/#{top}/hierarchy")
    room_ids = decode(conn)["rooms"] |> Enum.map(& &1["room_id"])
    assert top in room_ids
    refute restricted_room in room_ids

    join_conn = authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{top}/join", %{})
    assert join_conn.status == 200

    conn2 = authed(bob.token) |> get("/_matrix/client/v1/rooms/#{top}/hierarchy")
    room_ids2 = decode(conn2)["rooms"] |> Enum.map(& &1["room_id"])
    assert top in room_ids2
    assert restricted_room in room_ids2
  end

  test "pagination via limit/next_batch covers every room exactly once" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    top = space(alice.token, "Top")

    children =
      for n <- 1..5 do
        child = create_room(alice.token, %{"preset" => "public_chat", "name" => "Child#{n}"})
        add_child(alice.token, top, child)
        child
      end

    conn1 = authed(alice.token) |> get("/_matrix/client/v1/rooms/#{top}/hierarchy?limit=3")
    assert conn1.status == 200
    body1 = decode(conn1)
    page1_ids = Enum.map(body1["rooms"], & &1["room_id"])
    assert length(page1_ids) == 3
    assert is_binary(body1["next_batch"])

    conn2 =
      authed(alice.token)
      |> get("/_matrix/client/v1/rooms/#{top}/hierarchy?limit=3&from=#{body1["next_batch"]}")

    assert conn2.status == 200
    body2 = decode(conn2)
    page2_ids = Enum.map(body2["rooms"], & &1["room_id"])

    # Every room appears exactly once across the two pages, and the last
    # page carries no next_batch.
    all_ids = page1_ids ++ page2_ids
    assert Enum.sort(all_ids) == Enum.sort([top | children])
    assert length(Enum.uniq(all_ids)) == length(all_ids)
    refute Map.has_key?(body2, "next_batch")
  end
end
