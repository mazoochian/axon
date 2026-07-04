defmodule AxonWeb.OidcTest do
  @moduledoc """
  Phase 6 — delegated OAuth2/OIDC auth (MSC3861 + MSC2965 + MSC2964).

  Runs a fake local Authorization Server (AxonWeb.FakeOidcServer) to
  exercise the real HTTP round trips: discovery document caching,
  RFC 7662 introspection, scope/username extraction, and auto-provisioning
  of a local user/device from a token the fake AS recognizes.
  """

  use AxonWeb.ConnCase, async: false

  @port 18_199
  @issuer "http://127.0.0.1:#{@port}"

  setup do
    {:ok, pid} = Bandit.start_link(plug: AxonWeb.FakeOidcServer, ip: {127, 0, 0, 1}, port: @port)

    original = Application.get_env(:axon_web, :oidc)

    Application.put_env(:axon_web, :oidc,
      enabled: true,
      issuer: @issuer,
      client_id: "axon-test-client",
      client_secret: "axon-test-secret",
      client_auth_method: "client_secret_basic",
      account_management_url: "#{@issuer}/account"
    )

    :ets.delete_all_objects(:oidc_discovery_cache)

    on_exit(fn ->
      Application.put_env(:axon_web, :oidc, original)
      Process.exit(pid, :normal)
    end)

    :ok
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "GET /auth_metadata returns the AS discovery document when OIDC is enabled" do
    conn = build_conn() |> get("/_matrix/client/v1/auth_metadata")
    assert conn.status == 200
    body = decode(conn)

    assert body["issuer"] == @issuer
    assert body["introspection_endpoint"] == "#{@issuer}/introspect"
    assert body["account_management_uri"] == "#{@issuer}/account"
    assert "code" in body["response_types_supported"]
  end

  test "GET /auth_metadata returns 404 M_UNRECOGNIZED when OIDC is disabled" do
    Application.put_env(:axon_web, :oidc, enabled: false)

    conn = build_conn() |> get("/_matrix/client/v1/auth_metadata")
    assert conn.status == 404
    assert decode(conn)["errcode"] == "M_UNRECOGNIZED"
  end

  test "a Bearer token the AS recognizes authenticates via introspection and auto-provisions the user" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{AxonWeb.FakeOidcServer.valid_token()}")
      |> get("/_matrix/client/v3/account/whoami")

    assert conn.status == 200
    body = decode(conn)
    assert body["user_id"] == "@alice_oidc:localhost"
    assert body["device_id"] == "OIDCDEV1"

    # Second call reuses the same provisioned account rather than creating another.
    conn2 =
      build_conn()
      |> put_req_header("authorization", "Bearer #{AxonWeb.FakeOidcServer.valid_token()}")
      |> get("/_matrix/client/v3/account/whoami")

    assert decode(conn2)["user_id"] == body["user_id"]
  end

  test "an unrecognized Bearer token is rejected" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer some-bogus-token")
      |> get("/_matrix/client/v3/account/whoami")

    assert conn.status == 401
    assert decode(conn)["errcode"] == "M_UNKNOWN_TOKEN"
  end

  test "password login and registration are disabled while OIDC is enabled" do
    login_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/_matrix/client/v3/login", Jason.encode!(%{
        "type" => "m.login.password",
        "identifier" => %{"user" => "alice_oidc"},
        "password" => "whatever"
      }))

    assert login_conn.status == 403
    assert decode(login_conn)["errcode"] == "M_FORBIDDEN"

    flows_conn = build_conn() |> get("/_matrix/client/v3/login")
    assert decode(flows_conn)["flows"] == []

    register_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/_matrix/client/v3/register", Jason.encode!(%{
        "username" => "should_not_work",
        "password" => "Test1234!",
        "kind" => "user"
      }))

    assert register_conn.status == 403
    assert decode(register_conn)["errcode"] == "M_FORBIDDEN"
  end

  describe "device identity stability without an MSC2967 device scope" do
    defp whoami(token) do
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/_matrix/client/v3/account/whoami")
      |> decode()
    end

    test "a token whose introspection response has no device scope gets a stable fallback device_id" do
      token = AxonWeb.FakeOidcServer.valid_token_no_device_scope()

      first = whoami(token)
      assert is_binary(first["device_id"])

      for _ <- 1..3 do
        again = whoami(token)
        assert again["device_id"] == first["device_id"]
        assert again["user_id"] == first["user_id"]
      end
    end
  end

  describe "sensitive endpoints bypass password-based UIA while OIDC is enabled" do
    test "cross-signing key upload succeeds without an auth challenge" do
      token = AxonWeb.FakeOidcServer.valid_token()
      user_id = whoami(token)["user_id"]

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post(
          "/_matrix/client/v3/keys/device_signing/upload",
          Jason.encode!(%{
            "master_key" => %{
              "keys" => %{"ed25519:oidc_master_pub" => "oidc_master_key_value"},
              "usage" => ["master"],
              "user_id" => user_id
            }
          })
        )

      assert conn.status == 200
      assert decode(conn) == %{}
    end

    test "device deletion succeeds without an auth challenge" do
      token = AxonWeb.FakeOidcServer.valid_token_no_device_scope()
      device_id = whoami(token)["device_id"]

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/_matrix/client/v3/devices/#{device_id}")

      assert conn.status == 200
    end

    test "account deactivation succeeds without an auth challenge" do
      token = AxonWeb.FakeOidcServer.valid_token_no_device_scope()
      whoami(token)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/_matrix/client/v3/account/deactivate", Jason.encode!(%{}))

      assert conn.status == 200
      assert decode(conn)["id_server_unbind_result"] == "success"
    end

    test "password change is reported as disabled and rejected" do
      token = AxonWeb.FakeOidcServer.valid_token()

      capabilities_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/_matrix/client/v3/capabilities")

      assert decode(capabilities_conn)["capabilities"]["m.change_password"]["enabled"] == false

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post(
          "/_matrix/client/v3/account/password",
          Jason.encode!(%{"new_password" => "New1234!"})
        )

      assert conn.status == 403
      assert decode(conn)["errcode"] == "M_FORBIDDEN"
    end
  end
end
