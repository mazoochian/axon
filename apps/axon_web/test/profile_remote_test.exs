defmodule AxonWeb.ProfileRemoteTest do
  @moduledoc """
  Regression test: the client-facing profile GET endpoints must proxy to a
  remote user's homeserver instead of only ever checking the local
  `user_profiles` table (which previously 404'd on any non-local user_id).
  """

  use AxonWeb.ConnCase, async: false

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}

  @port 18_950
  @server_name "fake-profile.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
    :ok
  end

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
    %{token: Jason.decode!(conn.resp_body)["access_token"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "GET /profile/:user_id proxies to the remote user's homeserver" do
    local = register("local_profile_#{System.unique_integer([:positive])}")
    remote_user = "@someone:#{@server_name}"

    FakeRemoteMatrixServer.put_response(
      @port,
      {"GET", ~r{^/_matrix/federation/v1/query/profile}},
      200,
      %{"displayname" => "Someone Remote", "avatar_url" => "mxc://#{@server_name}/abc"}
    )

    conn = authed(local.token) |> get("/_matrix/client/v3/profile/#{URI.encode(remote_user)}")

    assert conn.status == 200
    body = decode(conn)
    assert body["displayname"] == "Someone Remote"
    assert body["avatar_url"] == "mxc://#{@server_name}/abc"
  end

  test "GET /profile/:user_id/displayname proxies to the remote user's homeserver" do
    local = register("local_profile2_#{System.unique_integer([:positive])}")
    remote_user = "@someone2:#{@server_name}"

    FakeRemoteMatrixServer.put_response(
      @port,
      {"GET", ~r{^/_matrix/federation/v1/query/profile}},
      200,
      %{"displayname" => "Remote Two", "avatar_url" => nil}
    )

    conn =
      authed(local.token)
      |> get("/_matrix/client/v3/profile/#{URI.encode(remote_user)}/displayname")

    assert conn.status == 200
    assert decode(conn)["displayname"] == "Remote Two"
  end

  test "GET /profile/:user_id 404s when the remote server errors" do
    local = register("local_profile3_#{System.unique_integer([:positive])}")
    remote_user = "@ghost:#{@server_name}"

    FakeRemoteMatrixServer.put_response(
      @port,
      {"GET", ~r{^/_matrix/federation/v1/query/profile}},
      404,
      %{"errcode" => "M_NOT_FOUND", "error" => "User not found"}
    )

    conn = authed(local.token) |> get("/_matrix/client/v3/profile/#{URI.encode(remote_user)}")

    assert conn.status == 404
  end
end
