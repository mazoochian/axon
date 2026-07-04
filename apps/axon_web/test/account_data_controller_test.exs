defmodule AxonWeb.AccountDataControllerTest do
  @moduledoc "Tests global and per-room account data get/put."

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

  test "global account data put then get round-trips" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    put_conn = authed(alice.token) |> jpu("/_matrix/client/v3/user/#{alice.user_id}/account_data/m.custom", %{"foo" => "bar"})
    assert put_conn.status == 200

    get_conn = authed(alice.token) |> get("/_matrix/client/v3/user/#{alice.user_id}/account_data/m.custom")
    assert decode(get_conn)["foo"] == "bar"
  end

  test "getting account data that was never set is not_found" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/user/#{alice.user_id}/account_data/m.never_set")
    assert conn.status == 404
  end

  test "cannot read another user's global account data" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    authed(alice.token) |> jpu("/_matrix/client/v3/user/#{alice.user_id}/account_data/m.custom", %{"secret" => true})

    conn = authed(bob.token) |> get("/_matrix/client/v3/user/#{alice.user_id}/account_data/m.custom")
    assert conn.status == 403
  end

  test "cannot write another user's global account data" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    conn = authed(bob.token) |> jpu("/_matrix/client/v3/user/#{alice.user_id}/account_data/m.custom", %{})
    assert conn.status == 403
  end

  test "room-scoped account data put then get round-trips" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_conn = authed(alice.token) |> jp("/_matrix/client/v3/createRoom", %{})
    room_id = decode(room_conn)["room_id"]

    put_conn = authed(alice.token) |> jpu("/_matrix/client/v3/user/#{alice.user_id}/rooms/#{room_id}/account_data/m.tag", %{"tags" => %{"favourite" => %{}}})
    assert put_conn.status == 200

    get_conn = authed(alice.token) |> get("/_matrix/client/v3/user/#{alice.user_id}/rooms/#{room_id}/account_data/m.tag")
    assert get_conn.status == 200
    assert Map.has_key?(decode(get_conn)["tags"], "favourite")
  end

  test "cannot access another user's room account data" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    room_conn = authed(alice.token) |> jp("/_matrix/client/v3/createRoom", %{})
    room_id = decode(room_conn)["room_id"]

    conn = authed(bob.token) |> get("/_matrix/client/v3/user/#{alice.user_id}/rooms/#{room_id}/account_data/m.tag")
    assert conn.status == 403
  end

  test "room account data that was never set is not_found" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_conn = authed(alice.token) |> jp("/_matrix/client/v3/createRoom", %{})
    room_id = decode(room_conn)["room_id"]

    conn = authed(alice.token) |> get("/_matrix/client/v3/user/#{alice.user_id}/rooms/#{room_id}/account_data/m.never_set")
    assert conn.status == 404
  end
end
