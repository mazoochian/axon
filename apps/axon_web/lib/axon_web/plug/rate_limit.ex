defmodule AxonWeb.Plug.RateLimit do
  @moduledoc """
  Gates an action behind `AxonWeb.RateLimiter`. Mounted per-controller-action
  via `plug AxonWeb.Plug.RateLimit, [...] when action in [:some_action]`
  rather than at the router/pipeline level, since the routes that need
  limiting (login, register, message send) each share a scope with other
  routes that don't.

  Opts:
    - `:bucket` — bucket name (atom), required. Looked up at request time
      (not baked in at compile time) in `Application.get_env(:axon_web, :rate_limits)[bucket]`,
      which must resolve to `[max: integer, window_ms: integer]` — this
      makes the limits themselves environment-configurable, notably so
      `config/test.exs` can set them high enough that the test suite's
      normal traffic (many registrations/logins/sends from the same
      loopback IP) never trips them.
    - `:key_by` — one of:
      - `:ip` (default) — the real TCP peer. No `RemoteIp`/XFF plug is in
        any pipeline, deliberately, so a forwarded-for header can't move a
        client between buckets.
      - `:user` — `conn.assigns.current_user_id`, falling back to IP if
        unset (for routes mounted after `AuthenticateToken`).
      - `:login_account` — the *account being attempted*, read out of a
        `/login` request body, for the one case where per-IP limiting
        answers the wrong question entirely. See below.

  ## Why `/login` needs a second, per-account dimension

  Per-IP limiting caps how fast one host can guess. It says nothing about
  how fast one *account* can be guessed at, because credential stuffing
  doesn't come from one host: a thousand IPs each trying ten passwords for
  `@alice` sail under a 10-per-minute per-IP limit while putting ten
  thousand guesses against Alice's password. The two limits are
  complementary — this is mounted *alongside* the per-IP one on the same
  action, not instead of it — and neither substitutes for the other.

  Requests with no identifiable account in the body are left to the per-IP
  limiter alone rather than being funnelled into one shared bucket, which
  would let anyone lock out every anonymous-shaped login on the server by
  spamming malformed bodies.
  """

  import Plug.Conn

  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    key_by = Keyword.get(opts, :key_by, :ip)
    {bucket, key_by}
  end

  def call(conn, {bucket, key_by}) do
    case key(conn, key_by) do
      nil -> conn
      key -> check(conn, bucket, key, key_by)
    end
  end

  # `:login_account` only *peeks* at the limit here — recording every
  # attempt (successes included, the way every other bucket does) would let
  # an attacker fill a victim's own bucket by repeatedly logging in *as*
  # them and lock the victim out of their own account, which is the exact
  # opposite of what an account-level limit is for. The controller records
  # a hit itself, only on a failed password, once it knows the outcome —
  # see `AuthController.do_login/2`'s call to `record_login_failure/1`.
  defp check(conn, bucket, key, :login_account) do
    [max: max, window_ms: window_ms] = Application.get_env(:axon_web, :rate_limits)[bucket]
    respond(conn, AxonWeb.RateLimiter.peek({bucket, key}, max, window_ms))
  end

  defp check(conn, bucket, key, _key_by) do
    [max: max, window_ms: window_ms] = Application.get_env(:axon_web, :rate_limits)[bucket]
    respond(conn, AxonWeb.RateLimiter.check({bucket, key}, max, window_ms))
  end

  defp respond(conn, :ok), do: conn

  defp respond(conn, {:error, retry_after_ms}) do
    conn
    |> put_status(429)
    |> Phoenix.Controller.json(%{
      "errcode" => "M_LIMIT_EXCEEDED",
      "error" => "Too many requests",
      "retry_after_ms" => retry_after_ms
    })
    |> halt()
  end

  @doc """
  Records a failed login attempt against the same `:login_account` bucket
  key this plug would have computed for `params` — called from
  `AuthController.do_login/2` once a password attempt is known to have
  failed, so the account-level limit tracks failures without a client's own
  successful logins ever counting against it.
  """
  @spec record_login_failure(map()) :: :ok
  def record_login_failure(params) do
    case login_account(params) do
      nil -> :ok
      key -> AxonWeb.RateLimiter.record_hit({:login_account, key})
    end
  end

  defp key(conn, :ip), do: ip(conn)
  defp key(conn, :user), do: conn.assigns[:current_user_id] || ip(conn)
  defp key(conn, :login_account), do: login_account(conn.body_params)

  defp ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  # Both shapes the C-S API allows: the current `identifier` object and the
  # deprecated top-level `user`, matching what AuthController.do_login/2
  # itself reads. Normalized so `Alice`, `alice` and `@alice:example.com`
  # share one bucket — otherwise the limit is bypassed by varying the
  # spelling of the very account being attacked.
  defp login_account(%{} = params) do
    # `params["identifier"]` is client-supplied and only ever *expected* to
    # be a map — a body sending it as a string/list/number would otherwise
    # raise out of `identifier["user"]` (`Access` isn't implemented for
    # those), turning a malformed request into a 500 instead of just falling
    # through to "no account identifiable, per-IP limiting only" below.
    identifier = case params["identifier"] do
      %{} = m -> m
      _ -> %{}
    end

    case identifier["user"] || params["user"] do
      user when is_binary(user) and user != "" ->
        user |> String.downcase() |> String.trim_leading("@") |> String.split(":") |> hd()

      _ ->
        nil
    end
  end

  defp login_account(_), do: nil
end
