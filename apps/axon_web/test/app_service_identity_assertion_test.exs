defmodule AxonWeb.AppService.IdentityAssertionTest do
  @moduledoc """
  Regression coverage for Application Service identity assertion
  (`AxonWeb.Plug.AuthenticateToken`): an AS authenticates with its
  `as_token` as the access token and can act as its own `sender_localpart`
  bot by default, or as any user in its `users` namespace via `?user_id=`,
  including lazily provisioning a "ghost" user that doesn't exist yet.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers
  import Ecto.Query

  alias AxonCore.Repo

  @table :axon_appservices

  setup do
    :ets.insert(@table, {:registrations, []})
    on_exit(fn -> :ets.insert(@table, {:registrations, []}) end)
    :ok
  end

  defp put_registration(reg), do: :ets.insert(@table, {:registrations, [reg]})

  defp bridge_registration(id, opts \\ []) do
    %{
      "id" => id,
      "url" => "http://127.0.0.1:1",
      "as_token" => "as-token-#{id}",
      "hs_token" => "hs-token-#{id}",
      "sender_localpart" => Keyword.get(opts, :sender_localpart, "_#{id}_bot"),
      "rate_limited" => Keyword.get(opts, :rate_limited, true),
      "namespaces" => %{
        "users" => [%{"regex" => "@#{id}_.*", "exclusive" => true}],
        "aliases" => [],
        "rooms" => []
      }
    }
  end

  defp whoami(token) do
    authed(token) |> get("/_matrix/client/v3/account/whoami")
  end

  test "as_token with no ?user_id= authenticates as the AS's own sender_localpart user" do
    reg = bridge_registration("idasrt1")
    put_registration(reg)

    conn = whoami(reg["as_token"])
    assert conn.status == 200
    assert decode(conn)["user_id"] == "@_idasrt1_bot:localhost"
  end

  test "?user_id= inside the AS's namespace authenticates as that user, provisioning it on first use" do
    reg = bridge_registration("idasrt2")
    put_registration(reg)

    ghost_id = "@idasrt2_ghost:localhost"
    refute Repo.exists?(from(u in "users", where: u.user_id == ^ghost_id))

    conn = authed(reg["as_token"]) |> get("/_matrix/client/v3/account/whoami?user_id=#{ghost_id}")
    assert conn.status == 200
    assert decode(conn)["user_id"] == ghost_id

    assert Repo.exists?(from(u in "users", where: u.user_id == ^ghost_id))
    # Ghost users are passwordless.
    assert Repo.one(from(u in "users", where: u.user_id == ^ghost_id, select: u.password_hash)) ==
             nil
  end

  test "?user_id= outside the AS's namespace is rejected with M_FORBIDDEN" do
    reg = bridge_registration("idasrt3")
    put_registration(reg)

    conn =
      authed(reg["as_token"])
      |> get("/_matrix/client/v3/account/whoami?user_id=@someone_else:localhost")

    assert conn.status == 403
    assert decode(conn)["errcode"] == "M_FORBIDDEN"
  end

  test "?device_id= naming a device that doesn't exist for the asserted user is rejected" do
    reg = bridge_registration("idasrt4")
    put_registration(reg)

    conn =
      authed(reg["as_token"])
      |> get("/_matrix/client/v3/account/whoami?user_id=@idasrt4_ghost:localhost&device_id=NOPE")

    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_UNKNOWN_DEVICE"
  end

  test "?device_id= naming a device that does exist for the asserted user is accepted" do
    reg = bridge_registration("idasrt5")
    put_registration(reg)
    ghost_id = "@idasrt5_ghost:localhost"

    # First call with no device_id lazily provisions both the user and the
    # default APPSERVICE device.
    conn1 =
      authed(reg["as_token"]) |> get("/_matrix/client/v3/account/whoami?user_id=#{ghost_id}")

    assert conn1.status == 200
    assert decode(conn1)["device_id"] == "APPSERVICE"

    conn2 =
      authed(reg["as_token"])
      |> get("/_matrix/client/v3/account/whoami?user_id=#{ghost_id}&device_id=APPSERVICE")

    assert conn2.status == 200
    assert decode(conn2)["device_id"] == "APPSERVICE"
  end

  test "an unknown token that happens to not match any as_token still gets the normal M_UNKNOWN_TOKEN response" do
    put_registration(bridge_registration("idasrt6"))
    conn = whoami("not-a-real-token-at-all")
    assert conn.status == 401
    assert decode(conn)["errcode"] == "M_UNKNOWN_TOKEN"
  end
end
