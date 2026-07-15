defmodule AxonWeb.PresenceControllerTest do
  @moduledoc "Tests presence get/put endpoints."

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

  defp jpu(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "put_status then get_status round-trips presence and status_msg" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    put_conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/presence/#{alice.user_id}/status", %{
        "presence" => "online",
        "status_msg" => "hi"
      })

    assert put_conn.status == 200

    get_conn = authed(alice.token) |> get("/_matrix/client/v3/presence/#{alice.user_id}/status")
    body = decode(get_conn)
    assert body["presence"] == "online"
    assert body["status_msg"] == "hi"
  end

  test "cannot set another user's presence" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/presence/#{bob.user_id}/status", %{"presence" => "online"})

    assert conn.status == 403
  end

  test "an invalid presence value is rejected" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/presence/#{alice.user_id}/status", %{"presence" => "bogus"})

    assert conn.status == 400
  end

  test "getting presence for a user who's never set any returns the offline default" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")

    conn = authed(alice.token) |> get("/_matrix/client/v3/presence/#{bob.user_id}/status")
    assert conn.status == 200
    assert decode(conn)["presence"] == "offline"
  end
end
