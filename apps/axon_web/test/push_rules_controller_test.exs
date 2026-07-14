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

  defp jpu(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

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

    conn =
      authed(alice.token) |> get("/_matrix/client/v3/pushrules/global/override/.m.rule.master")

    assert conn.status == 200
    assert decode(conn)["rule_id"] == ".m.rule.master"
  end

  test "get_rule for an unknown rule_id 404s" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> get("/_matrix/client/v3/pushrules/global/override/.m.rule.nonexistent")

    assert conn.status == 404
  end

  test "put_rule persists a real custom rule, retrievable via get_rule/index" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    put_conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/pushrules/global/override/custom", %{
        "conditions" => [
          %{"kind" => "event_match", "key" => "type", "pattern" => "m.room.message"}
        ],
        "actions" => ["notify"]
      })

    assert put_conn.status == 200
    assert decode(put_conn) == %{}

    get_conn = authed(alice.token) |> get("/_matrix/client/v3/pushrules/global/override/custom")
    assert get_conn.status == 200
    rule = decode(get_conn)
    assert rule["rule_id"] == "custom"
    assert rule["actions"] == ["notify"]
    assert rule["default"] == false

    index_conn = authed(alice.token) |> get("/_matrix/client/v3/pushrules/")
    override_ids = decode(index_conn)["global"]["override"] |> Enum.map(& &1["rule_id"])
    assert "custom" in override_ids
  end

  test "put_rule_enabled/put_rule_actions override a server-default rule without replacing its conditions" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    enabled_conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/pushrules/global/override/.m.rule.master/enabled", %{
        "enabled" => true
      })

    assert enabled_conn.status == 200

    actions_conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/pushrules/global/override/.m.rule.master/actions", %{
        "actions" => ["dont_notify"]
      })

    assert actions_conn.status == 200

    get_conn =
      authed(alice.token) |> get("/_matrix/client/v3/pushrules/global/override/.m.rule.master")

    rule = decode(get_conn)
    assert rule["enabled"] == true
    assert rule["actions"] == ["dont_notify"]
    # conditions are the server default's, untouched — .m.rule.master has none.
    assert rule["conditions"] == []
  end

  test "put_rule refuses to replace a server-default rule's own body" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/pushrules/global/override/.m.rule.master", %{
        "conditions" => [],
        "actions" => ["notify"]
      })

    assert conn.status == 400
  end

  test "delete_rule removes a custom rule" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    authed(alice.token)
    |> jpu("/_matrix/client/v3/pushrules/global/override/custom", %{
      "conditions" => [],
      "actions" => []
    })

    del_conn =
      authed(alice.token) |> delete("/_matrix/client/v3/pushrules/global/override/custom")

    assert del_conn.status == 200

    get_conn = authed(alice.token) |> get("/_matrix/client/v3/pushrules/global/override/custom")
    assert get_conn.status == 404
  end

  test "delete_rule on a default-rule override reverts it to the true default" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    authed(alice.token)
    |> jpu("/_matrix/client/v3/pushrules/global/override/.m.rule.master/enabled", %{
      "enabled" => true
    })

    authed(alice.token) |> delete("/_matrix/client/v3/pushrules/global/override/.m.rule.master")

    get_conn =
      authed(alice.token) |> get("/_matrix/client/v3/pushrules/global/override/.m.rule.master")

    # True default: disabled.
    assert decode(get_conn)["enabled"] == false
  end

  test "custom rules for different users don't leak into each other's ruleset" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")

    authed(alice.token)
    |> jpu("/_matrix/client/v3/pushrules/global/room/!aliceroom:localhost", %{
      "actions" => ["dont_notify"]
    })

    bob_conn =
      authed(bob.token) |> get("/_matrix/client/v3/pushrules/global/room/!aliceroom:localhost")

    assert bob_conn.status == 404
  end
end
