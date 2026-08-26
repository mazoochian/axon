defmodule AxonWeb.SharedSecretRegistrationTest do
  @moduledoc """
  The Synapse-compatible shared-secret admin bootstrap,
  `GET/POST /_synapse/admin/v1/register`.

  The MAC on this endpoint *is* its authentication — there is no token, no
  session, nothing else between a caller and a brand-new full-admin account.
  It used to be keyed by a compiled-in literal (`"complement"`) with no
  environment override anywhere in the repo, which meant every Axon
  deployment in existence shipped the same publicly-readable key to its own
  admin API. These tests pin the three properties that closes:

    * the secret comes from configuration, so two deployments don't share one;
    * an unset secret makes the endpoint *absent* (404 M_UNRECOGNIZED), never
      falling back to a default; and
    * a MAC computed with the wrong secret — including the old literal — is
      refused.

  Everything goes through the real router and the real `UserStore`, against
  the real database, so a pass means an account genuinely was (or wasn't)
  created.
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import AxonWeb.TestHelpers

  alias AxonCore.Repo

  @secret "s3cret-for-this-deployment-only"

  setup do
    previous = Application.get_env(:axon_web, :registration_shared_secret)
    Application.put_env(:axon_web, :registration_shared_secret, @secret)
    on_exit(fn -> Application.put_env(:axon_web, :registration_shared_secret, previous) end)
    :ok
  end

  defp nonce do
    conn = build_conn() |> get("/_synapse/admin/v1/register")
    assert conn.status == 200
    decode(conn)["nonce"]
  end

  defp mac(secret, nonce, username, password, admin?) do
    admin_str = if admin?, do: "admin", else: "notadmin"
    data = nonce <> "\x00" <> username <> "\x00" <> password <> "\x00" <> admin_str
    :crypto.mac(:hmac, :sha, secret, data) |> Base.encode16(case: :lower)
  end

  defp register_with(secret, username, opts \\ []) do
    admin? = Keyword.get(opts, :admin, true)
    password = Keyword.get(opts, :password, "Test1234!")
    nonce = Keyword.get(opts, :nonce) || nonce()

    build_conn()
    |> jp("/_synapse/admin/v1/register", %{
      "nonce" => nonce,
      "username" => username,
      "password" => password,
      "admin" => admin?,
      "mac" => mac(secret, nonce, username, password, admin?)
    })
  end

  defp user_exists?(user_id) do
    Repo.exists?(from(u in "users", where: u.user_id == ^user_id))
  end

  describe "with a configured shared secret" do
    test "a MAC computed with that secret mints the account" do
      username = "ssr_ok_#{System.unique_integer([:positive])}"
      conn = register_with(@secret, username)

      assert conn.status == 200
      body = decode(conn)
      assert body["user_id"] == "@#{username}:localhost"
      assert is_binary(body["access_token"])

      # ...and the account is real and really an admin, not just echoed back.
      assert user_exists?(body["user_id"])

      assert authed(body["access_token"]) |> get("/_synapse/admin/v1/users") |> Map.fetch!(:status) ==
               200
    end

    test "a MAC computed with the old hardcoded literal is refused" do
      username = "ssr_literal_#{System.unique_integer([:positive])}"
      conn = register_with("complement", username)

      assert conn.status == 403
      assert decode(conn)["errcode"] == "M_FORBIDDEN"
      refute user_exists?("@#{username}:localhost")
    end

    test "a MAC computed with any other guessed secret is refused" do
      username = "ssr_guess_#{System.unique_integer([:positive])}"
      conn = register_with("hunter2", username)

      assert conn.status == 403
      refute user_exists?("@#{username}:localhost")
    end

    test "a missing or malformed mac is refused rather than crashing" do
      username = "ssr_nomac_#{System.unique_integer([:positive])}"

      for bad_mac <- [nil, "", "not-hex", 12_345] do
        conn =
          build_conn()
          |> jp("/_synapse/admin/v1/register", %{
            "nonce" => nonce(),
            "username" => username,
            "password" => "Test1234!",
            "admin" => true,
            "mac" => bad_mac
          })

        assert conn.status == 403, "mac #{inspect(bad_mac)} was not refused"
      end

      refute user_exists?("@#{username}:localhost")
    end

    test "the MAC covers the admin flag, so it can't be flipped after signing" do
      username = "ssr_flip_#{System.unique_integer([:positive])}"
      nonce = nonce()
      password = "Test1234!"

      conn =
        build_conn()
        |> jp("/_synapse/admin/v1/register", %{
          "nonce" => nonce,
          "username" => username,
          "password" => password,
          # Signed as a plain user, submitted asking for admin.
          "admin" => true,
          "mac" => mac(@secret, nonce, username, password, false)
        })

      assert conn.status == 403
      refute user_exists?("@#{username}:localhost")
    end
  end

  describe "with no shared secret configured" do
    setup do
      Application.put_env(:axon_web, :registration_shared_secret, nil)
      :ok
    end

    test "the nonce endpoint reports itself as unrecognized" do
      conn = build_conn() |> get("/_synapse/admin/v1/register")

      assert conn.status == 404
      assert decode(conn)["errcode"] == "M_UNRECOGNIZED"
      refute Map.has_key?(decode(conn), "nonce")
    end

    test "the register endpoint reports itself as unrecognized, whatever MAC is offered" do
      username = "ssr_off_#{System.unique_integer([:positive])}"

      # A caller can't even get a nonce now, so supply one of their own —
      # which is exactly what an attacker replaying a known flow would do.
      for secret <- ["complement", @secret, ""] do
        conn = register_with(secret, username, nonce: "deadbeef")

        assert conn.status == 404
        assert decode(conn)["errcode"] == "M_UNRECOGNIZED"
      end

      refute user_exists?("@#{username}:localhost")
    end

    test "an empty-string secret counts as unset, not as a usable key" do
      Application.put_env(:axon_web, :registration_shared_secret, "")
      username = "ssr_empty_#{System.unique_integer([:positive])}"

      assert build_conn() |> get("/_synapse/admin/v1/register") |> Map.fetch!(:status) == 404
      assert register_with("", username, nonce: "deadbeef") |> Map.fetch!(:status) == 404
      refute user_exists?("@#{username}:localhost")
    end
  end

  describe "rate limiting" do
    setup do
      previous = Application.get_env(:axon_web, :rate_limits)

      Application.put_env(
        :axon_web,
        :rate_limits,
        Keyword.put(previous, :admin_register, max: 3, window_ms: 60_000)
      )

      on_exit(fn -> Application.put_env(:axon_web, :rate_limits, previous) end)

      # The {:admin_register, "127.0.0.1"} bucket is global ETS shared with
      # every other test in this file (and with the sibling test in this
      # describe block, whichever order they run in) — clear it so the
      # 3-request limit set above starts from zero rather than partly
      # spent. Same reasoning, and same mechanism, as rate_limit_test.exs's
      # login-bucket clear.
      :ets.match_delete(:axon_rate_limiter, {{:admin_register, :_}, :_})
      :ok
    end

    test "unlimited MAC guessing against the register endpoint is throttled" do
      username = "ssr_rl_#{System.unique_integer([:positive])}"

      # Each of these is a wrong-secret guess, i.e. exactly the attack the
      # limit exists to slow down. The nonce fetches share the same bucket,
      # so use a fixed one rather than burning the budget on GETs.
      statuses =
        for _ <- 1..6 do
          register_with("wrong-secret", username, nonce: "deadbeef") |> Map.fetch!(:status)
        end

      assert 429 in statuses
      assert Enum.take(statuses, 3) == [403, 403, 403]
      refute user_exists?("@#{username}:localhost")
    end

    test "the nonce endpoint is throttled too" do
      statuses =
        for _ <- 1..6 do
          build_conn() |> get("/_synapse/admin/v1/register") |> Map.fetch!(:status)
        end

      assert 429 in statuses
    end
  end
end
