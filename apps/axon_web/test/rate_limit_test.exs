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
end
