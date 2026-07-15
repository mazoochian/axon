defmodule AxonWeb.SearchControllerTest do
  @moduledoc "Tests full-text message search, including the joined-rooms-only security boundary."

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

  defp send_message(token, room_id, body) do
    txn = "txn_#{System.unique_integer([:positive])}"

    conn =
      authed(token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn}", %{
        "msgtype" => "m.text",
        "body" => body
      })

    assert conn.status == 200
    decode(conn)["event_id"]
  end

  defp search(token, term, extra \\ %{}) do
    body = %{
      "search_categories" => %{"room_events" => Map.merge(%{"search_term" => term}, extra)}
    }

    authed(token) |> jp("/_matrix/client/v3/search", body)
  end

  test "finds a message in a joined room" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    unique = "zephyrquokka#{System.unique_integer([:positive])}"
    send_message(alice.token, room_id, "the #{unique} jumped over the fence")

    conn = search(alice.token, unique)
    assert conn.status == 200
    results = decode(conn)["search_categories"]["room_events"]["results"]
    assert length(results) == 1
    assert results |> hd() |> get_in(["result", "content", "body"]) =~ unique
  end

  test "does not return results from a room the searcher hasn't joined" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    unique = "topsecretphrase#{System.unique_integer([:positive])}"
    send_message(alice.token, room_id, unique)

    conn = search(bob.token, unique)
    assert conn.status == 200
    assert decode(conn)["search_categories"]["room_events"]["results"] == []
  end

  test "missing search_term is a required-param error" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/search", %{"search_categories" => %{"room_events" => %{}}})

    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_MISSING_PARAM"
  end

  test "filter.rooms is intersected with joined rooms, not trusted outright" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    alice_room = create_room(alice.token)
    bob_room = create_room(bob.token)
    unique = "crosstenant#{System.unique_integer([:positive])}"
    send_message(bob.token, bob_room, unique)

    # Alice claims bob's room in her filter — should still return nothing since she isn't a member.
    conn = search(alice.token, unique, %{"filter" => %{"rooms" => [bob_room, alice_room]}})
    assert decode(conn)["search_categories"]["room_events"]["results"] == []
  end

  test "a non-matching term returns zero results with count 0" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    send_message(alice.token, room_id, "hello world")

    conn = search(alice.token, "zzz_definitely_not_present_zzz")
    body = decode(conn)["search_categories"]["room_events"]
    assert body["count"] == 0
    assert body["results"] == []
  end

  test "results include timeline context" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    unique = "contexttest#{System.unique_integer([:positive])}"
    send_message(alice.token, room_id, "before message")
    send_message(alice.token, room_id, unique)
    send_message(alice.token, room_id, "after message")

    conn = search(alice.token, unique)
    [result] = decode(conn)["search_categories"]["room_events"]["results"]
    assert is_list(result["context"]["events_before"])
    assert is_list(result["context"]["events_after"])
  end
end
