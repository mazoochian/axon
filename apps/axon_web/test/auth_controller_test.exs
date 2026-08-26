defmodule AxonWeb.AuthControllerTest do
  @moduledoc """
  Tests `AuthController` actions with thin prior coverage: whoami, logout,
  logout_all, synapse-admin registration. (register/login with m.login.dummy
  are already exercised heavily as helpers throughout the rest of the suite.)
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
    %{token: body["access_token"], user_id: body["user_id"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp jp(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "whoami returns the authenticated user_id" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/account/whoami")
    assert conn.status == 200
    assert decode(conn)["user_id"] == alice.user_id
  end

  test "whoami without a token is rejected" do
    conn = build_conn() |> get("/_matrix/client/v3/account/whoami")
    assert conn.status == 401
  end

  test "logout invalidates the token used" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    logout_conn = authed(alice.token) |> jp("/_matrix/client/v3/logout", %{})
    assert logout_conn.status == 200

    conn = authed(alice.token) |> get("/_matrix/client/v3/account/whoami")
    assert conn.status == 401
  end

  test "logout_all invalidates every device's token" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    login_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/login",
        Jason.encode!(%{
          "type" => "m.login.password",
          "identifier" => %{"user" => alice.user_id},
          "password" => "Test1234!"
        })
      )

    second_token = decode(login_conn)["access_token"]

    authed(alice.token) |> jp("/_matrix/client/v3/logout/all", %{})

    assert (authed(alice.token) |> get("/_matrix/client/v3/account/whoami")).status == 401
    assert (authed(second_token) |> get("/_matrix/client/v3/account/whoami")).status == 401
  end

  test "a non-map identifier in a login body doesn't crash — falls through to the missing-param case" do
    conn =
      build_conn()
      |> jp("/_matrix/client/v3/login", %{
        "type" => "m.login.password",
        "identifier" => "not_an_object",
        "password" => "whatever"
      })

    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_MISSING_PARAM"
  end

  test "register_available reports true for a free username and false when taken" do
    free_conn =
      build_conn()
      |> get(
        "/_matrix/client/v3/register/available?username=free_#{System.unique_integer([:positive])}"
      )

    assert free_conn.status == 200
    assert decode(free_conn)["available"] == true

    taken_localpart = "taken_#{System.unique_integer([:positive])}"
    register(taken_localpart)

    taken_conn =
      build_conn() |> get("/_matrix/client/v3/register/available?username=#{taken_localpart}")

    assert taken_conn.status == 400
  end

  describe "registration_enabled gate" do
    setup do
      original = Application.get_env(:axon_web, :registration)
      on_exit(fn -> Application.put_env(:axon_web, :registration, original) end)
      :ok
    end

    test "register is rejected with Synapse's 403 M_FORBIDDEN shape when registration is disabled" do
      Application.put_env(:axon_web, :registration, enabled: false)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/_matrix/client/v3/register",
          Jason.encode!(%{
            "username" => "shouldbeblocked_#{System.unique_integer([:positive])}",
            "password" => "Test1234!",
            "kind" => "user",
            "auth" => %{"type" => "m.login.dummy"}
          })
        )

      assert conn.status == 403
      body = decode(conn)
      assert body["errcode"] == "M_FORBIDDEN"
      assert body["error"] == "Registration has been disabled"
    end

    test "register/available is rejected the same way when registration is disabled" do
      Application.put_env(:axon_web, :registration, enabled: false)

      conn =
        build_conn()
        |> get("/_matrix/client/v3/register/available?username=whatever_#{System.unique_integer([:positive])}")

      assert conn.status == 403
      body = decode(conn)
      assert body["errcode"] == "M_FORBIDDEN"
      assert body["error"] == "Registration has been disabled"
    end

    test "register succeeds normally when registration is enabled" do
      Application.put_env(:axon_web, :registration, enabled: true)

      alice = register("regenabled_#{System.unique_integer([:positive])}")
      assert alice.user_id
      assert alice.token
    end

    test "OIDC's own registration response takes precedence over the registration flag" do
      Application.put_env(:axon_web, :registration, enabled: true)
      original_oidc = Application.get_env(:axon_web, :oidc)
      Application.put_env(:axon_web, :oidc, enabled: true, issuer: "https://as.example.com")
      on_exit(fn -> Application.put_env(:axon_web, :oidc, original_oidc) end)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/_matrix/client/v3/register",
          Jason.encode!(%{"username" => "oidcblocked", "kind" => "user"})
        )

      assert conn.status == 403
      assert decode(conn)["error"] =~ "Authorization Server"
    end
  end

  describe "synapse-admin shared-secret registration" do
    test "register with a correct HMAC succeeds" do
      nonce_conn = build_conn() |> get("/_synapse/admin/v1/register")
      nonce = decode(nonce_conn)["nonce"]
      username = "adminreg_#{System.unique_integer([:positive])}"
      password = "Test1234!"

      mac =
        :crypto.mac(
          :hmac,
          :sha,
          "complement",
          "#{nonce}\x00#{username}\x00#{password}\x00notadmin"
        )
        |> Base.encode16(case: :lower)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/_synapse/admin/v1/register",
          Jason.encode!(%{
            "nonce" => nonce,
            "username" => username,
            "password" => password,
            "mac" => mac,
            "admin" => false
          })
        )

      assert conn.status == 200
      assert decode(conn)["user_id"] =~ username
    end

    test "register with a wrong HMAC is rejected" do
      nonce_conn = build_conn() |> get("/_synapse/admin/v1/register")
      nonce = decode(nonce_conn)["nonce"]

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/_synapse/admin/v1/register",
          Jason.encode!(%{
            "nonce" => nonce,
            "username" => "shouldfail_#{System.unique_integer([:positive])}",
            "password" => "Test1234!",
            "mac" => "0000000000000000000000000000000000000000",
            "admin" => false
          })
        )

      assert conn.status == 403
    end
  end
end
