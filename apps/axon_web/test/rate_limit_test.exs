defmodule AxonWeb.RateLimitTest do
  @moduledoc """
  Regression tests for Phase 13's rate limiting: `AxonWeb.RateLimiter`
  directly (small, explicit limits — the app-wide config in
  `config/test.exs` is deliberately set high so the rest of the suite's
  normal traffic never trips it) and the `AxonWeb.Plug.RateLimit` 429
  response shape end-to-end via a temporarily-lowered `login` bucket.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonWeb.RateLimiter

  test "check/3 allows up to max requests per window, then rejects with retry_after_ms" do
    key = {:test_bucket, "unique_#{System.unique_integer([:positive])}"}

    assert RateLimiter.check(key, 3, 60_000) == :ok
    assert RateLimiter.check(key, 3, 60_000) == :ok
    assert RateLimiter.check(key, 3, 60_000) == :ok

    assert {:error, retry_after_ms} = RateLimiter.check(key, 3, 60_000)
    assert retry_after_ms > 0
    assert retry_after_ms <= 60_000
  end

  test "check/3 allows requests again once the window has passed" do
    key = {:test_bucket, "expiring_#{System.unique_integer([:positive])}"}

    assert RateLimiter.check(key, 1, 50) == :ok
    assert {:error, _} = RateLimiter.check(key, 1, 50)

    Process.sleep(80)

    assert RateLimiter.check(key, 1, 50) == :ok
  end

  test "distinct bucket keys are independent" do
    key_a = {:test_bucket, "a_#{System.unique_integer([:positive])}"}
    key_b = {:test_bucket, "b_#{System.unique_integer([:positive])}"}

    assert RateLimiter.check(key_a, 1, 60_000) == :ok
    assert {:error, _} = RateLimiter.check(key_a, 1, 60_000)
    assert RateLimiter.check(key_b, 1, 60_000) == :ok
  end

  test "the login plug returns 429 M_LIMIT_EXCEEDED once the configured limit is exceeded" do
    original = Application.get_env(:axon_web, :rate_limits)
    on_exit(fn -> Application.put_env(:axon_web, :rate_limits, original) end)

    Application.put_env(
      :axon_web,
      :rate_limits,
      Keyword.put(original, :login, max: 2, window_ms: 60_000)
    )

    # Every test in this suite hits /login from the same loopback IP, so
    # the shared {:login, "127.0.0.1"} ETS bucket already has a long
    # history by the time this test runs — clear it so the 2-request limit
    # set above actually starts from zero instead of being pre-exhausted.
    :ets.match_delete(:axon_rate_limiter, {{:login, :_}, :_})

    username = "rl_login_#{System.unique_integer([:positive])}"
    register(username)

    login_body = %{
      "type" => "m.login.password",
      "identifier" => %{"type" => "m.id.user", "user" => username},
      "password" => "wrong-password"
    }

    conn1 = build_conn() |> jp("/_matrix/client/v3/login", login_body)
    conn2 = build_conn() |> jp("/_matrix/client/v3/login", login_body)
    conn3 = build_conn() |> jp("/_matrix/client/v3/login", login_body)

    assert conn1.status == 403
    assert conn2.status == 403
    assert conn3.status == 429
    body = decode(conn3)
    assert body["errcode"] == "M_LIMIT_EXCEEDED"
    assert is_integer(body["retry_after_ms"])
  end

  # ---------------------------------------------------------------------------
  # Coverage gaps closed (audit L1)
  #
  # Each of these endpoints checks a credential — a password through
  # `Argon2.verify_pass`, or a refresh token — and had nothing throttling
  # it at all. `config/test.exs` deliberately sets every bucket to
  # 1,000,000 so the rest of the suite's traffic never trips one, so each
  # test lowers just the bucket it's about and clears its ETS keys first
  # (the whole suite shares one loopback IP, so a per-IP bucket already has
  # history by the time any of these run).
  # ---------------------------------------------------------------------------

  defp with_limit(bucket, max, window_ms) do
    original = Application.get_env(:axon_web, :rate_limits)
    on_exit(fn -> Application.put_env(:axon_web, :rate_limits, original) end)

    Application.put_env(
      :axon_web,
      :rate_limits,
      Keyword.put(original, bucket, max: max, window_ms: window_ms)
    )

    :ets.match_delete(:axon_rate_limiter, {{bucket, :_}, :_})
    :ok
  end

  describe "POST /refresh" do
    test "is throttled per IP" do
      with_limit(:refresh, 2, 60_000)

      body = %{"refresh_token" => "not-a-real-refresh-token"}

      assert build_conn() |> jp("/_matrix/client/v3/refresh", body) |> Map.get(:status) == 401
      assert build_conn() |> jp("/_matrix/client/v3/refresh", body) |> Map.get(:status) == 401

      conn = build_conn() |> jp("/_matrix/client/v3/refresh", body)
      assert conn.status == 429
      assert decode(conn)["errcode"] == "M_LIMIT_EXCEEDED"
    end
  end

  describe "the password-verifying UIA endpoints" do
    setup do
      with_limit(:ui_auth, 2, 60_000)
      user = register("rl_uia_#{System.unique_integer([:positive])}")
      %{user: user}
    end

    defp ui_auth_body(user_id, password) do
      %{
        "new_password" => "Whatever1234!",
        "auth" => %{
          "type" => "m.login.password",
          "identifier" => %{"type" => "m.id.user", "user" => user_id},
          "password" => password
        }
      }
    end

    test "POST /account/password stops answering after the limit", %{user: user} do
      # Wrong password on purpose: this is the shape of an attacker using a
      # stolen access token to guess the password that would let them log
      # every other device out.
      body = ui_auth_body(user.user_id, "not-the-password")
      path = "/_matrix/client/v3/account/password"

      assert authed(user.token) |> jp(path, body) |> Map.get(:status) == 401
      assert authed(user.token) |> jp(path, body) |> Map.get(:status) == 401

      conn = authed(user.token) |> jp(path, body)
      assert conn.status == 429
      assert decode(conn)["errcode"] == "M_LIMIT_EXCEEDED"
    end

    test "POST /account/deactivate shares the same bucket as /account/password", %{user: user} do
      # One bucket on purpose: both stages verify the same password with the
      # same primitive, so two separate 10-per-minute limits would be one
      # 20-per-minute limit wearing a hat.
      body = ui_auth_body(user.user_id, "not-the-password")

      assert authed(user.token)
             |> jp("/_matrix/client/v3/account/password", body)
             |> Map.get(:status) == 401

      assert authed(user.token)
             |> jp("/_matrix/client/v3/account/deactivate", body)
             |> Map.get(:status) == 401

      conn = authed(user.token) |> jp("/_matrix/client/v3/account/deactivate", body)
      assert conn.status == 429
    end

    test "another user's attempts are counted separately", %{user: user} do
      other = register("rl_uia_other_#{System.unique_integer([:positive])}")
      path = "/_matrix/client/v3/account/password"

      Enum.each(1..2, fn _ ->
        authed(user.token) |> jp(path, ui_auth_body(user.user_id, "wrong"))
      end)

      assert authed(user.token)
             |> jp(path, ui_auth_body(user.user_id, "wrong"))
             |> Map.get(:status) == 429

      # Keyed per user, not per IP — every test in this suite comes from
      # 127.0.0.1, so a per-IP key here would have locked out a completely
      # unrelated account.
      assert authed(other.token)
             |> jp(path, ui_auth_body(other.user_id, "wrong"))
             |> Map.get(:status) == 401
    end
  end

  describe "per-account login limiting" do
    setup do
      with_limit(:login_account, 2, 60_000)
      :ok
    end

    defp login_attempt(conn, user, password \\ "wrong-password") do
      jp(conn, "/_matrix/client/v3/login", %{
        "type" => "m.login.password",
        "identifier" => %{"type" => "m.id.user", "user" => user},
        "password" => password
      })
    end

    test "throttles guesses against one account regardless of source IP" do
      username = "rl_acct_#{System.unique_integer([:positive])}"
      register(username)

      # Three different source addresses — the per-IP `login` bucket is
      # untouched by all of this, which is exactly the gap: distributed
      # credential stuffing against one account used to be unthrottled.
      from = fn ip -> %{build_conn() | remote_ip: ip} end

      assert from.({203, 0, 113, 1}) |> login_attempt(username) |> Map.get(:status) == 403
      assert from.({203, 0, 113, 2}) |> login_attempt(username) |> Map.get(:status) == 403

      conn = from.({203, 0, 113, 3}) |> login_attempt(username)
      assert conn.status == 429
      assert decode(conn)["errcode"] == "M_LIMIT_EXCEEDED"
    end

    test "a different account from the same IP is unaffected" do
      target = "rl_acct_target_#{System.unique_integer([:positive])}"
      bystander = "rl_acct_bystander_#{System.unique_integer([:positive])}"
      register(target)
      register(bystander)

      Enum.each(1..3, fn _ -> build_conn() |> login_attempt(target) end)
      assert build_conn() |> login_attempt(target) |> Map.get(:status) == 429

      assert build_conn() |> login_attempt(bystander) |> Map.get(:status) == 403
    end

    test "spelling the same account differently does not buy fresh attempts" do
      username = "rl_acct_norm_#{System.unique_integer([:positive])}"
      register(username)

      assert build_conn() |> login_attempt(username) |> Map.get(:status) == 403

      # Uppercase and the full `@user:server` form are the same account.
      assert build_conn() |> login_attempt(String.upcase(username)) |> Map.get(:status) == 403
      assert build_conn() |> login_attempt("@#{username}:localhost") |> Map.get(:status) == 429
    end

    test "a login body naming no account falls through to the per-IP limit alone" do
      # Otherwise every malformed login on the server shares one bucket, and
      # anyone can shut that bucket — and so every anonymous-shaped login —
      # by spamming junk.
      body = %{"type" => "m.login.password", "password" => "x"}

      Enum.each(1..5, fn _ ->
        conn = build_conn() |> jp("/_matrix/client/v3/login", body)
        assert conn.status == 400
      end)
    end

    test "a successful login is not counted against the account's own bucket" do
      username = "rl_acct_ok_#{System.unique_integer([:positive])}"
      register(username)

      # Well past the configured max of 2 — if a success recorded a hit the
      # way a failure does, this account would have locked itself out on its
      # own legitimate traffic long before request 5.
      Enum.each(1..5, fn _ ->
        assert build_conn() |> login_attempt(username, "Test1234!") |> Map.get(:status) == 200
      end)
    end

    test "the account's own ordinary successful logins don't eat into the quota an attacker would need to fill" do
      username = "rl_acct_quota_#{System.unique_integer([:positive])}"
      register(username)

      # The owner logging in normally, repeatedly, well past the max: if a
      # success recorded a hit the way a failure does, this alone would have
      # used up the account's whole (max: 2) quota already.
      Enum.each(1..4, fn _ ->
        assert build_conn() |> login_attempt(username, "Test1234!") |> Map.get(:status) == 200
      end)

      # The account's failure-quota is still fully intact afterwards — an
      # attacker starting now needs exactly `max` failed guesses, not fewer,
      # regardless of how much the account was legitimately used first.
      assert build_conn() |> login_attempt(username) |> Map.get(:status) == 403
      assert build_conn() |> login_attempt(username) |> Map.get(:status) == 403
      assert build_conn() |> login_attempt(username) |> Map.get(:status) == 429
    end
  end
end
