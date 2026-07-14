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
    - `:key_by` — `:ip` (default) or `:user` (keys by
      `conn.assigns.current_user_id`, falling back to IP if unset — for
      routes mounted after `AuthenticateToken`).
  """

  import Plug.Conn

  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    key_by = Keyword.get(opts, :key_by, :ip)
    {bucket, key_by}
  end

  def call(conn, {bucket, key_by}) do
    [max: max, window_ms: window_ms] = Application.get_env(:axon_web, :rate_limits)[bucket]
    bucket_key = {bucket, key(conn, key_by)}

    case AxonWeb.RateLimiter.check(bucket_key, max, window_ms) do
      :ok ->
        conn

      {:error, retry_after_ms} ->
        conn
        |> put_status(429)
        |> Phoenix.Controller.json(%{
          "errcode" => "M_LIMIT_EXCEEDED",
          "error" => "Too many requests",
          "retry_after_ms" => retry_after_ms
        })
        |> halt()
    end
  end

  defp key(conn, :ip), do: ip(conn)
  defp key(conn, :user), do: conn.assigns[:current_user_id] || ip(conn)

  defp ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
