defmodule AxonWeb.AppServiceAuthTest do
  @moduledoc """
  End-to-end tests for `AxonWeb.Plug.AuthenticateToken`'s application
  service branch: an `as_token` authenticates as the AS's own
  `sender_localpart` user by default, or as any other user matching one
  of its registered namespaces via `?user_id=` impersonation — both
  provisioning the target user's account on first use, since an
  appservice's ghost users never go through `/register`.

  Regression for Complement's TestJoinFederatedRoomFromApplicationServiceBridgeUser
  (and the appservice-driven subtests of TestJumpToDateEndpoint): axon
  never read the Synapse-style registration YAML Complement writes into
  every homeserver container (see AxonWeb.AppService.RegistrationYaml),
  so an as_token was always just an unrecognized token — every appservice
  request 401'd with M_UNKNOWN_TOKEN before this.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers
  import Ecto.Query, only: [from: 2]

  @table :axon_appservices

  defp put_registrations(regs) do
    :ets.insert(@table, {:registrations, regs})
    on_exit(fn -> :ets.insert(@table, {:registrations, []}) end)
  end

  setup do
    :ets.insert(@table, {:registrations, []})
    :ok
  end

  defp bridge_registration(id, as_token, opts \\ []) do
    %{
      "id" => id,
      "as_token" => as_token,
      "hs_token" => "hs-tok-#{id}",
      "sender_localpart" => Keyword.get(opts, :sender_localpart, "the-bridge-user-#{id}"),
      "namespaces" => %{
        "users" => Keyword.get(opts, :user_namespaces, []),
        "rooms" => []
      }
    }
  end

  defp as_authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  test "an as_token authenticates as the appservice's own sender_localpart user" do
    put_registrations([bridge_registration("bridge1", "as-secret-1")])

    conn = as_authed("as-secret-1") |> get("/_matrix/client/v3/account/whoami")

    assert conn.status == 200
    assert decode(conn)["user_id"] == "@the-bridge-user-bridge1:localhost"
  end

  test "the sender_localpart user is provisioned on first use, not pre-registered" do
    put_registrations([bridge_registration("bridge2", "as-secret-2")])

    assert AxonCore.EventStore.room_exists?("!doesnotmatter") == false
    refute match?({:ok, _}, AxonCore.UserStore.get_user("@the-bridge-user-bridge2:localhost"))

    conn = as_authed("as-secret-2") |> get("/_matrix/client/v3/account/whoami")
    assert conn.status == 200

    assert match?({:ok, _}, AxonCore.UserStore.get_user("@the-bridge-user-bridge2:localhost"))
  end

  test "the same as_token resolves to the same user and device across requests" do
    put_registrations([bridge_registration("bridge3", "as-secret-3")])

    conn1 = as_authed("as-secret-3") |> get("/_matrix/client/v3/account/whoami")
    conn2 = as_authed("as-secret-3") |> get("/_matrix/client/v3/account/whoami")

    assert decode(conn1)["user_id"] == decode(conn2)["user_id"]

    count =
      AxonCore.Repo.aggregate(
        from(d in "devices", where: d.user_id == "@the-bridge-user-bridge3:localhost"),
        :count
      )

    assert count == 1
  end

  test "?user_id= impersonates a user matching the appservice's namespace" do
    put_registrations([
      bridge_registration("bridge4", "as-secret-4",
        user_namespaces: [%{"regex" => "@ghost4_.*", "exclusive" => true}]
      )
    ])

    conn =
      as_authed("as-secret-4")
      |> get("/_matrix/client/v3/account/whoami?user_id=@ghost4_1:localhost")

    assert conn.status == 200
    assert decode(conn)["user_id"] == "@ghost4_1:localhost"
  end

  test "?user_id= for a user outside the appservice's namespace is rejected" do
    put_registrations([
      bridge_registration("bridge5", "as-secret-5",
        user_namespaces: [%{"regex" => "@ghost5_.*", "exclusive" => true}]
      )
    ])

    conn =
      as_authed("as-secret-5")
      |> get("/_matrix/client/v3/account/whoami?user_id=@someone_unrelated:localhost")

    assert conn.status == 401
    assert decode(conn)["errcode"] == "M_UNKNOWN_TOKEN"
  end

  test "an unrecognized token still 401s as before" do
    put_registrations([bridge_registration("bridge6", "as-secret-6")])

    conn = as_authed("not-a-real-token") |> get("/_matrix/client/v3/account/whoami")

    assert conn.status == 401
    assert decode(conn)["errcode"] == "M_UNKNOWN_TOKEN"
  end

  test "an appservice user can join a room, exercising the full request pipeline" do
    put_registrations([bridge_registration("bridge7", "as-secret-7")])

    alice = register("aliceasjoin_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    conn = as_authed("as-secret-7") |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
  end

  # Manager.load_registrations/0 (the actual boot-time path — see
  # AxonWeb.AppService.RegistrationYaml's moduledoc) only runs once, in
  # init/1, so it isn't reachable per-test without restarting the
  # singleton GenServer other tests in this describe block share. This
  # instead exercises the exact same real file → RegistrationYaml.parse/1
  # → registration map pipeline the loader uses, then feeds the result
  # through the same public ETS contract the rest of this file relies on —
  # covering everything except the file-discovery glob itself, which
  # RegistrationYamlTest and Manager's own JSON-loader tests don't
  # exercise via a real file either.
  test "a registration parsed from a real Complement-shaped YAML file authenticates identically" do
    yaml = """
    id: my_as_id
    hs_token: hs-secret-yaml
    as_token: as-secret-yaml
    url: 'http://localhost:9000'
    sender_localpart: the-bridge-user
    rate_limited: false
    de.sorunome.msc2409.push_ephemeral: false
    push_ephemeral: false
    org.matrix.msc3202: false
    namespaces:
      users:
        - exclusive: false
          regex: .*
      rooms: []
      aliases: []
    """

    {:ok, registration} = AxonWeb.AppService.RegistrationYaml.parse(yaml)
    put_registrations([registration])

    conn = as_authed("as-secret-yaml") |> get("/_matrix/client/v3/account/whoami")

    assert conn.status == 200
    assert decode(conn)["user_id"] == "@the-bridge-user:localhost"
  end
end
