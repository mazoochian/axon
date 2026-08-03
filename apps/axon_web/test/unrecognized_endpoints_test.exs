defmodule AxonWeb.UnrecognizedEndpointsTest do
  @moduledoc """
  Unknown `/_matrix` endpoints must answer 404 `M_UNRECOGNIZED`, and a known
  path called with an unsupported method must answer 405 `M_UNRECOGNIZED` —
  not the generic 404 `M_NOT_FOUND` Phoenix's render_errors path produced
  before `AxonWeb.UnrecognizedController` existed.

  Mirrors Complement's `TestUnknownEndpoints`, which checks every `_matrix`
  prefix (client, federation, key, media) plus a wholly unknown one.
  """

  use AxonWeb.ConnCase, async: false

  defp get_json(path) do
    conn = build_conn() |> get(path)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  describe "unknown endpoints return 404 M_UNRECOGNIZED" do
    test "a prefix the Matrix project doesn't define at all" do
      assert {404, %{"errcode" => "M_UNRECOGNIZED"}} = get_json("/_matrix/unknown")
    end

    test "unknown client-server endpoints" do
      assert {404, %{"errcode" => "M_UNRECOGNIZED"}} = get_json("/_matrix/client/unknown")
      # The version prefix exists; the endpoint under it does not.
      assert {404, %{"errcode" => "M_UNRECOGNIZED"}} = get_json("/_matrix/client/v1/unknown")
      assert {404, %{"errcode" => "M_UNRECOGNIZED"}} = get_json("/_matrix/client/v3/room/unknown")
    end

    test "unknown server-server endpoints" do
      assert {404, %{"errcode" => "M_UNRECOGNIZED"}} = get_json("/_matrix/federation/unknown")
      assert {404, %{"errcode" => "M_UNRECOGNIZED"}} = get_json("/_matrix/federation/v1/unknown")
    end

    test "unknown key endpoints" do
      assert {404, %{"errcode" => "M_UNRECOGNIZED"}} = get_json("/_matrix/key/unknown")
      assert {404, %{"errcode" => "M_UNRECOGNIZED"}} = get_json("/_matrix/key/v2/unknown")
    end

    test "unknown media endpoints" do
      assert {404, %{"errcode" => "M_UNRECOGNIZED"}} = get_json("/_matrix/media/unknown")
      assert {404, %{"errcode" => "M_UNRECOGNIZED"}} = get_json("/_matrix/media/v3/unknown")
    end
  end

  describe "known endpoints called with the wrong method return 405 M_UNRECOGNIZED" do
    test "PUT on /_matrix/client/v3/login (POST-only)" do
      conn = build_conn() |> put("/_matrix/client/v3/login")
      assert conn.status == 405
      assert %{"errcode" => "M_UNRECOGNIZED"} = Jason.decode!(conn.resp_body)
    end

    test "PUT on /_matrix/federation/v1/version (GET-only)" do
      conn = build_conn() |> put("/_matrix/federation/v1/version")
      assert conn.status == 405
      assert %{"errcode" => "M_UNRECOGNIZED"} = Jason.decode!(conn.resp_body)
    end

    test "PUT on /_matrix/key/v2/query (GET/POST-only)" do
      conn = build_conn() |> put("/_matrix/key/v2/query")
      assert conn.status == 405
      assert %{"errcode" => "M_UNRECOGNIZED"} = Jason.decode!(conn.resp_body)
    end

    test "PATCH on /_matrix/media/v3/upload (POST-only)" do
      conn = build_conn() |> patch("/_matrix/media/v3/upload")
      assert conn.status == 405
      assert %{"errcode" => "M_UNRECOGNIZED"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "GET /_matrix/federation/v1/version" do
    test "is served unauthenticated and names the server" do
      assert {200, body} = get_json("/_matrix/federation/v1/version")
      assert %{"server" => %{"name" => name, "version" => version}} = body
      assert is_binary(name) and name != ""
      assert is_binary(version)
    end
  end
end
