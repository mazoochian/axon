defmodule AxonWeb.PushRulesControllerTest do
  @moduledoc """
  Tests push rules retrieval (real) and mutation (documented no-op stubs —
  pinned explicitly so it's clear that's intended, not silently broken).
  """

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
    %{token: body["access_token"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
  defp jpu(conn, path, body), do: conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "index returns the default global ruleset" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/pushrules/")
    assert conn.status == 200
    assert Map.has_key?(decode(conn)["global"], "override")
  end

  test "get_scope for global returns the ruleset" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/pushrules/global/")
    assert conn.status == 200
    assert Map.has_key?(decode(conn), "global")
  end

  test "get_scope for an unknown scope 404s" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/pushrules/device/")
    assert conn.status == 404
  end

  test "get_rule returns a known default rule" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/pushrules/global/override/.m.rule.master")
    assert conn.status == 200
    assert decode(conn)["rule_id"] == ".m.rule.master"
  end

  test "get_rule for an unknown rule_id 404s" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/pushrules/global/override/.m.rule.nonexistent")
    assert conn.status == 404
  end

  test "put_rule/delete_rule/put_rule_enabled/put_rule_actions are documented no-op stubs" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    put_conn = authed(alice.token) |> jpu("/_matrix/client/v3/pushrules/global/override/custom", %{"conditions" => [], "actions" => []})
    assert put_conn.status == 200
    assert decode(put_conn) == %{}

    enabled_conn = authed(alice.token) |> jpu("/_matrix/client/v3/pushrules/global/override/custom/enabled", %{"enabled" => true})
    assert enabled_conn.status == 200

    actions_conn = authed(alice.token) |> jpu("/_matrix/client/v3/pushrules/global/override/custom/actions", %{"actions" => ["notify"]})
    assert actions_conn.status == 200

    del_conn = authed(alice.token) |> delete("/_matrix/client/v3/pushrules/global/override/custom")
    assert del_conn.status == 200

    # Stub confirmed: the rule never actually got created by put_rule above.
    get_conn = authed(alice.token) |> get("/_matrix/client/v3/pushrules/global/override/custom")
    assert get_conn.status == 404
  end
end
