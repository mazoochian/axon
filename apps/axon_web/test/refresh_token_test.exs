defmodule AxonWeb.RefreshTokenTest do
  @moduledoc """
  Refresh tokens (stable Matrix spec, formerly MSC2918): `POST /login` and
  `POST /register` with `refresh_token: true`, `POST /refresh` rotation,
  and that plain login/register (no `refresh_token` requested) keeps
  behaving exactly as before this feature existed.
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  alias AxonCore.Repo

  defp jp(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp register(username, extra \\ %{}) do
    build_conn()
    |> jp(
      "/_matrix/client/v3/register",
      Map.merge(
        %{
          "username" => username,
          "password" => "Test1234!",
          "kind" => "user",
          "auth" => %{"type" => "m.login.dummy"}
        },
        extra
      )
    )
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  describe "login/register with refresh_token: true" do
    test "register issues both an access_token and a refresh_token, with a real expiry" do
      conn = register(unique("reg_refresh"), %{"refresh_token" => true})
      assert conn.status == 200
      body = decode(conn)

      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      assert body["access_token"] != body["refresh_token"]
      assert is_integer(body["expires_in_ms"])
      assert body["expires_in_ms"] > 0
      # Default is 5 minutes (300_000ms), matching Synapse's own
      # `refreshable_access_token_lifetime` default — allow generous slack
      # for wall-clock drift between issuing and asserting.
      assert body["expires_in_ms"] <= 300_000
      assert body["expires_in_ms"] > 290_000
    end

    test "login issues both an access_token and a refresh_token" do
      username = unique("login_refresh")
      register(username)

      conn =
        build_conn()
        |> jp("/_matrix/client/v3/login", %{
          "type" => "m.login.password",
          "identifier" => %{"user" => "@#{username}:localhost"},
          "password" => "Test1234!",
          "refresh_token" => true
        })

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      assert is_integer(body["expires_in_ms"])

      # The minted access token actually works.
      whoami = authed(body["access_token"]) |> get("/_matrix/client/v3/account/whoami")
      assert whoami.status == 200
    end

    test "the minted access_token really does expire (not just present in the response)" do
      username = unique("expiry_check")
      conn = register(username, %{"refresh_token" => true})
      token = decode(conn)["access_token"]

      # Confirm it works right after being issued.
      assert (authed(token) |> get("/_matrix/client/v3/account/whoami")).status == 200

      # Force it into the past directly, the same way the passage of real
      # time eventually would (AuthenticateToken/UserStore.validate_token
      # is what actually enforces expires_at_ms — this exercises that
      # enforcement without a 5-minute sleep).
      hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
      past = System.os_time(:millisecond) - 1_000

      {1, _} =
        Repo.update_all(
          from(t in "access_tokens", where: t.token_hash == ^hash),
          set: [expires_at_ms: past]
        )

      conn2 = authed(token) |> get("/_matrix/client/v3/account/whoami")
      assert conn2.status == 401
      assert decode(conn2)["errcode"] == "M_UNKNOWN_TOKEN"
    end
  end

  describe "plain login/register (no refresh_token requested) is unaffected" do
    test "register without refresh_token omits expires_in_ms and refresh_token entirely" do
      conn = register(unique("reg_plain"))
      assert conn.status == 200
      body = decode(conn)

      assert is_binary(body["access_token"])
      refute Map.has_key?(body, "refresh_token")
      refute Map.has_key?(body, "expires_in_ms")
    end

    test "login without refresh_token omits expires_in_ms and refresh_token entirely" do
      username = unique("login_plain")
      register(username)

      conn =
        build_conn()
        |> jp("/_matrix/client/v3/login", %{
          "type" => "m.login.password",
          "identifier" => %{"user" => "@#{username}:localhost"},
          "password" => "Test1234!"
        })

      assert conn.status == 200
      body = decode(conn)
      refute Map.has_key?(body, "refresh_token")
      refute Map.has_key?(body, "expires_in_ms")
    end

    test "an access_token minted without refresh_token never expires (still nil in storage)" do
      conn = register(unique("reg_noexpiry"))
      token = decode(conn)["access_token"]
      hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

      expires_at_ms =
        Repo.one(from(t in "access_tokens", where: t.token_hash == ^hash, select: t.expires_at_ms))

      assert is_nil(expires_at_ms)
    end
  end

  describe "POST /refresh" do
    test "rotates: returns a new access_token + refresh_token, and the old refresh_token stops working" do
      conn = register(unique("rotate"), %{"refresh_token" => true})
      body = decode(conn)
      old_access = body["access_token"]
      old_refresh = body["refresh_token"]

      refresh_conn =
        build_conn() |> jp("/_matrix/client/v3/refresh", %{"refresh_token" => old_refresh})

      assert refresh_conn.status == 200
      new_body = decode(refresh_conn)

      assert is_binary(new_body["access_token"])
      assert is_binary(new_body["refresh_token"])
      assert is_integer(new_body["expires_in_ms"])
      assert new_body["access_token"] != old_access
      assert new_body["refresh_token"] != old_refresh

      # The new access token authenticates as the same session/device.
      whoami = authed(new_body["access_token"]) |> get("/_matrix/client/v3/account/whoami")
      assert whoami.status == 200

      # Re-using the now-rotated-away old refresh_token fails.
      replay_conn =
        build_conn() |> jp("/_matrix/client/v3/refresh", %{"refresh_token" => old_refresh})

      assert replay_conn.status == 403
      assert decode(replay_conn)["errcode"] == "M_FORBIDDEN"
    end

    test "carries the same device_id forward across a refresh (refreshes the existing login, not a new one)" do
      conn = register(unique("samedevice"), %{"refresh_token" => true, "device_id" => "FIXEDDEV"})
      body = decode(conn)
      assert body["device_id"] == "FIXEDDEV"

      refresh_conn =
        build_conn()
        |> jp("/_matrix/client/v3/refresh", %{"refresh_token" => body["refresh_token"]})

      new_access = decode(refresh_conn)["access_token"]

      whoami = authed(new_access) |> get("/_matrix/client/v3/account/whoami")
      assert decode(whoami)["device_id"] == "FIXEDDEV"
    end

    test "a never-issued (garbage) refresh_token 401s with M_UNKNOWN_TOKEN" do
      conn =
        build_conn()
        |> jp("/_matrix/client/v3/refresh", %{"refresh_token" => "not_a_real_refresh_token"})

      assert conn.status == 401
      assert decode(conn)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    test "missing refresh_token param is a 400 M_MISSING_PARAM" do
      conn = build_conn() |> jp("/_matrix/client/v3/refresh", %{})
      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_MISSING_PARAM"
    end

    test "logging out a device invalidates its refresh_token too" do
      conn = register(unique("logout_kills_refresh"), %{"refresh_token" => true})
      body = decode(conn)

      logout_conn = authed(body["access_token"]) |> jp("/_matrix/client/v3/logout", %{})
      assert logout_conn.status == 200

      refresh_conn =
        build_conn()
        |> jp("/_matrix/client/v3/refresh", %{"refresh_token" => body["refresh_token"]})

      assert refresh_conn.status in [401, 403]
      refute refresh_conn.status == 200
    end
  end
end
