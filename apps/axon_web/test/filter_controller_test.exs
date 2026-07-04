defmodule AxonWeb.FilterControllerTest do
  @moduledoc "Tests sync filter creation/retrieval."

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
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "create then get round-trips the filter definition" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    filter = %{"room" => %{"timeline" => %{"limit" => 10}}}

    create_conn = authed(alice.token) |> jp("/_matrix/client/v3/user/#{alice.user_id}/filter", filter)
    assert create_conn.status == 200
    filter_id = decode(create_conn)["filter_id"]
    assert is_binary(filter_id)

    get_conn = authed(alice.token) |> get("/_matrix/client/v3/user/#{alice.user_id}/filter/#{filter_id}")
    assert get_conn.status == 200
    assert decode(get_conn)["room"]["timeline"]["limit"] == 10
  end

  test "cannot create a filter for another user" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")

    conn = authed(alice.token) |> jp("/_matrix/client/v3/user/#{bob.user_id}/filter", %{})
    assert conn.status == 403
  end

  test "cannot get another user's filter" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")

    create_conn = authed(alice.token) |> jp("/_matrix/client/v3/user/#{alice.user_id}/filter", %{})
    filter_id = decode(create_conn)["filter_id"]

    conn = authed(bob.token) |> get("/_matrix/client/v3/user/#{alice.user_id}/filter/#{filter_id}")
    assert conn.status == 403
  end

  test "getting an unknown filter_id 404s" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/user/#{alice.user_id}/filter/nonexistent")
    assert conn.status == 404
  end

  test "rejects a filter where room.timeline.types is not an array" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    filter = %{"room" => %{"timeline" => %{"types" => "not_an_array"}}}

    conn = authed(alice.token) |> jp("/_matrix/client/v3/user/#{alice.user_id}/filter", filter)
    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_BAD_JSON"
  end

  test "rejects a filter where room.timeline.senders contains an invalid user id" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    filter = %{"room" => %{"timeline" => %{"senders" => ["not-a-user-id"]}}}

    conn = authed(alice.token) |> jp("/_matrix/client/v3/user/#{alice.user_id}/filter", filter)
    assert conn.status == 400
  end

  test "rejects a filter where presence is not an object" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> jp("/_matrix/client/v3/user/#{alice.user_id}/filter", %{"presence" => "nope"})
    assert conn.status == 400
  end

  test "accepts a minimal empty filter" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> jp("/_matrix/client/v3/user/#{alice.user_id}/filter", %{})
    assert conn.status == 200
  end
end
