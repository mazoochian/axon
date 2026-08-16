defmodule AxonWeb.OpenidTokens do
  @moduledoc """
  Short-lived OpenID tokens (Matrix C-S API `POST
  /_matrix/client/v3/user/{userId}/openid/request_token`), ETS-backed —
  same GenServer+ETS shape `AxonWeb.RateLimiter` already uses for exactly
  the same reason: a small, self-contained, restart-is-fine need.

  These aren't Axon's own login access tokens — they're the
  spec-defined, single-purpose bearer tokens a client hands to a *third
  party* (an identity server, here) so that party can verify the client's
  Matrix user ID by calling back to this homeserver's federation
  `GET /_matrix/federation/v1/openid/userinfo` (`AxonWeb.FederationController.openid_userinfo/2`).
  Also used internally by `AxonWeb.IdentityServer.ensure_access_token/2` to
  self-register with `DEFAULT_IDENTITY_SERVER` when a client invites a 3pid
  without supplying its own `id_access_token`.
  """

  use GenServer

  @table :axon_openid_tokens
  # Matches the `expires_in` (seconds) returned to the caller.
  @ttl_ms :timer.minutes(30)
  @tick_interval :timer.minutes(5)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Mints a fresh token for `user_id`. Returns `{token, expires_in_seconds}`."
  @spec issue(String.t()) :: {String.t(), pos_integer()}
  def issue(user_id) do
    token = "openid_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {token, user_id, expires_at})
    {token, div(@ttl_ms, 1000)}
  end

  @doc "Returns `{:ok, user_id}` for a live token, or `:error` if unknown/expired."
  @spec verify(String.t()) :: {:ok, String.t()} | :error
  def verify(token) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, token) do
      [{^token, user_id, expires_at}] when expires_at > now -> {:ok, user_id}
      _ -> :error
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    match_spec = [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}]
    :ets.select_delete(@table, match_spec)
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)
end
