defmodule AxonWeb.SyncPushRulesTest do
  @moduledoc """
  `m.push_rules` was entirely absent from `/sync`'s `account_data.events`
  (Complement's `TestPushSync`) — it isn't a row ever written to the
  generic `account_data` table, so `AxonWeb.SyncHelpers.get_global_account_data/3`
  never had anything to return for it. It's now always computed live from
  `AxonPush.UserRules.effective_rules/1` and included on every sync,
  initial or incremental.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  defp sync(token, opts \\ []) do
    since = Keyword.get(opts, :since)
    qs = if since, do: "?since=#{since}&timeout=0", else: "?timeout=0"
    conn = authed(token) |> get("/_matrix/client/v3/sync#{qs}")
    assert conn.status == 200
    decode(conn)
  end

  defp push_rules_global(sync_resp) do
    sync_resp["account_data"]["events"]
    |> Enum.find(&(&1["type"] == "m.push_rules"))
    |> then(& &1 && &1["content"]["global"])
  end

  test "an initial sync includes m.push_rules with the server defaults" do
    alice = register("sprt_init_#{System.unique_integer([:positive])}")

    global = sync(alice.token) |> push_rules_global()

    assert global != nil
    assert Map.has_key?(global, "override")
    assert Map.has_key?(global, "underride")
  end

  test "an incremental sync still includes m.push_rules" do
    alice = register("sprt_incr_#{System.unique_integer([:positive])}")
    since = sync(alice.token)["next_batch"]

    global = sync(alice.token, since: since) |> push_rules_global()

    assert global != nil
  end

  test "customizing a push rule is reflected on the next sync" do
    alice = register("sprt_custom_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/pushrules/global/room/!foo:example.com/enabled", %{
        "enabled" => false
      })

    assert conn.status == 200

    global = sync(alice.token) |> push_rules_global()
    room_rules = global["room"]
    rule = Enum.find(room_rules, &(&1["rule_id"] == "!foo:example.com"))

    assert rule["enabled"] == false
  end
end
