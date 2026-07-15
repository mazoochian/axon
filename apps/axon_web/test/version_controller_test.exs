defmodule AxonWeb.VersionControllerTest do
  @moduledoc "Tests /versions, /capabilities, media_config, 3pid stubs."

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
    %{token: body["access_token"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "GET /versions lists supported spec versions, no auth required" do
    conn = build_conn() |> get("/_matrix/client/versions")
    assert conn.status == 200
    assert "v1.1" in decode(conn)["versions"]
  end

  test "GET /capabilities reports room versions and change_password enabled without OIDC" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/capabilities")
    assert conn.status == 200
    caps = decode(conn)["capabilities"]
    assert caps["m.change_password"]["enabled"] == true
    assert caps["m.room_versions"]["default"] == "11"
  end

  test "capabilities requires authentication" do
    conn = build_conn() |> get("/_matrix/client/v3/capabilities")
    assert conn.status == 401
  end

  test "media_config is public and returns an upload size limit" do
    conn = build_conn() |> get("/_matrix/client/v3/media/config")
    assert conn.status == 200
    assert decode(conn)["m.upload.size"] > 0
  end

  test "3pid endpoints are spec-compliant stubs" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    get_conn = authed(alice.token) |> get("/_matrix/client/v3/account/3pid")
    assert decode(get_conn)["threepids"] == []

    post_conn =
      authed(alice.token)
      |> put_req_header("content-type", "application/json")
      |> post("/_matrix/client/v3/account/3pid", Jason.encode!(%{}))

    assert post_conn.status == 200
  end
end
