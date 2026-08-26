defmodule AxonWeb.UserDirectoryControllerTest do
  @moduledoc "Tests user directory search."

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

  defp search(token, term),
    do: authed(token) |> jp("/_matrix/client/v3/user_directory/search", %{"search_term" => term})

  defp create_room(token, opts) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", opts)
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp join(token, room_id) do
    conn = authed(token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    assert conn.status == 200
  end

  defp make_publicly_visible(user) do
    create_room(user.token, %{"preset" => "public_chat", "visibility" => "public"})
  end

  defp set_display_name(user, display_name) do
    conn =
      authed(user.token)
      |> jpu("/_matrix/client/v3/profile/#{user.user_id}/displayname", %{
        "displayname" => display_name
      })

    assert conn.status == 200
  end

  defp assert_global_name_is_authoritative(searcher, target, global_name, room_name) do
    assert decode(search(searcher.token, room_name))["results"] == []

    assert decode(search(searcher.token, global_name))["results"] == [
             %{"display_name" => global_name, "user_id" => target.user_id}
           ]
  end

  test "requester sees only shared-room and public-room candidates, excluding self" do
    prefix = "user-#{System.unique_integer([:positive])}"
    requester = register("#{prefix}-requester")
    shared = register("#{prefix}-shared")
    public = register("#{prefix}-public")
    unrelated = register("#{prefix}-unrelated")

    shared_room =
      create_room(requester.token, %{"preset" => "public_chat", "visibility" => "private"})

    join(shared.token, shared_room)
    make_publicly_visible(public)

    results = decode(search(requester.token, prefix))["results"]
    result_ids = Enum.map(results, & &1["user_id"])

    assert result_ids == Enum.sort([public.user_id, shared.user_id])
    refute requester.user_id in result_ids
    refute unrelated.user_id in result_ids

    leave_conn =
      authed(shared.token) |> jp("/_matrix/client/v3/rooms/#{shared_room}/leave", %{})

    assert leave_conn.status == 200

    assert decode(search(requester.token, prefix))["results"] == [
             %{"display_name" => "#{prefix}-public", "user_id" => public.user_id}
           ]
  end

  test "TestRoomSpecificUsernameChange: a post-join room display name is not globally searchable" do
    suffix = System.unique_integer([:positive])
    alice = register("user-#{suffix}-alice")
    bob = register("user-#{suffix}-bob")
    eve = register("user-#{suffix}-eve")
    global_name = "Alice Public #{suffix}"
    room_name = "Alice Private Changed #{suffix}"

    set_display_name(alice, global_name)
    make_publicly_visible(alice)

    private_room =
      create_room(bob.token, %{"preset" => "public_chat", "visibility" => "private"})

    join(alice.token, private_room)

    override =
      authed(alice.token)
      |> jpu(
        "/_matrix/client/v3/rooms/#{private_room}/state/m.room.member/#{alice.user_id}",
        %{"displayname" => room_name, "membership" => "join"}
      )

    assert override.status == 200

    membership =
      authed(bob.token)
      |> get("/_matrix/client/v3/rooms/#{private_room}/state/m.room.member/#{alice.user_id}")
      |> decode()

    assert membership["displayname"] == room_name
    assert_global_name_is_authoritative(bob, alice, global_name, room_name)
    assert_global_name_is_authoritative(eve, alice, global_name, room_name)
  end

  test "TestRoomSpecificUsernameAtJoin: a join-time room display name is not globally searchable" do
    suffix = System.unique_integer([:positive])
    alice = register("user-#{suffix}-alice")
    bob = register("user-#{suffix}-bob")
    global_name = "Alice Public Join #{suffix}"
    room_name = "Alice Private At Join #{suffix}"

    set_display_name(alice, global_name)
    make_publicly_visible(alice)

    private_room =
      create_room(bob.token, %{"preset" => "public_chat", "visibility" => "private"})

    join_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/join/#{private_room}", %{"displayname" => room_name})

    assert join_conn.status == 200

    membership =
      authed(bob.token)
      |> get("/_matrix/client/v3/rooms/#{private_room}/state/m.room.member/#{alice.user_id}")
      |> decode()

    assert membership["displayname"] == room_name
    assert_global_name_is_authoritative(bob, alice, global_name, room_name)
  end

  test "finds a user by localpart substring" do
    unique = "zorbleflug#{System.unique_integer([:positive])}"
    target = register(unique)
    make_publicly_visible(target)
    searcher = register("searcher_#{System.unique_integer([:positive])}")

    conn = search(searcher.token, unique)
    assert conn.status == 200
    assert Enum.any?(decode(conn)["results"], &(&1["user_id"] == target.user_id))
  end

  test "finds a user by display name substring" do
    target = register("displaytest_#{System.unique_integer([:positive])}")
    make_publicly_visible(target)
    unique_name = "Quazzlefrob #{System.unique_integer([:positive])}"

    authed(target.token)
    |> jpu("/_matrix/client/v3/profile/#{target.user_id}/displayname", %{
      "displayname" => unique_name
    })

    searcher = register("searcher2_#{System.unique_integer([:positive])}")
    conn = search(searcher.token, unique_name)
    assert Enum.any?(decode(conn)["results"], &(&1["user_id"] == target.user_id))
  end

  test "an empty search term returns no results" do
    searcher = register("searcher3_#{System.unique_integer([:positive])}")
    conn = search(searcher.token, "")
    assert decode(conn)["results"] == []
  end

  test "a deactivated user is excluded from results" do
    unique = "deactivatedsearch#{System.unique_integer([:positive])}"
    target = register(unique)
    make_publicly_visible(target)

    authed(target.token)
    |> jp("/_matrix/client/v3/account/deactivate", %{
      "auth" => %{
        "type" => "m.login.password",
        "identifier" => %{"user" => target.user_id},
        "password" => "Test1234!"
      }
    })

    searcher = register("searcher4_#{System.unique_integer([:positive])}")
    conn = search(searcher.token, unique)
    refute Enum.any?(decode(conn)["results"], &(&1["user_id"] == target.user_id))
  end

  test "the limited flag is true when results hit the limit" do
    prefix = "limtest#{System.unique_integer([:positive])}"

    for i <- 1..3 do
      register("#{prefix}_#{i}") |> make_publicly_visible()
    end

    searcher = register("searcher5_#{System.unique_integer([:positive])}")

    conn =
      authed(searcher.token)
      |> jp("/_matrix/client/v3/user_directory/search", %{"search_term" => prefix, "limit" => 2})

    body = decode(conn)
    assert length(body["results"]) == 2

    assert Enum.map(body["results"], & &1["user_id"]) ==
             Enum.sort(Enum.map(body["results"], & &1["user_id"]))

    assert body["limited"] == true
  end
end
