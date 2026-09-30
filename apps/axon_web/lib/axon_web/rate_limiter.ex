defmodule AxonWeb.RateLimiter do
  @moduledoc """
  Simple in-memory sliding-window rate limiter, ETS-backed — mirrors the
  GenServer+ETS pattern `AxonSync.Typing` already uses for exactly the same
  reason: this is a small, self-contained need, not worth a new dependency
  for. Resets on restart, which is an accepted tradeoff for a single-node
  deployment like this one (a persistent rate limiter would need to survive
  restarts to matter for a determined attacker, but the value here is
  mainly about accidental abuse/bugs, not defeating a sophisticated one).
  """

  use GenServer

  @table :axon_rate_limiter
  @tick_interval :timer.seconds(30)
  @max_key_age :timer.minutes(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Checks whether `bucket_key` has made fewer than `max_requests` calls in
  the last `window_ms`. An accepted call records a fresh timestamp; a
  rejected one does not — re-checking against an already-full window must
  not keep pushing that window's start forward, or a client that keeps
  getting rejected would never age back out of it.

  Atomic under concurrency: the hit is recorded *before* counting and
  withdrawn again if it went over, so concurrent callers always see each
  other's hits and can never all squeeze in under the same limit.

  Returns `:ok` or `{:error, retry_after_ms}`.
  """
  def check(bucket_key, max_requests, window_ms) do
    now = System.monotonic_time(:millisecond)
    hit = {bucket_key, now, make_ref()}
    :ets.insert(@table, hit)

    case decide(bucket_key, max_requests, window_ms, now) do
      :ok ->
        :ok

      error ->
        :ets.delete_object(@table, hit)
        error
    end
  end

  @doc """
  Same decision as `check/3` — fewer than `max_requests` calls recorded in
  the last `window_ms` — but never records this call itself. For a bucket
  that must only count a specific *outcome* of the gated action rather than
  every attempt at it (see `AxonWeb.Plug.RateLimit`'s `:login_account`
  dimension: counting every login attempt, successful ones included, would
  let an attacker fill a victim's own bucket and lock the victim out of
  their own account — the opposite of what account-level limiting is for).
  Pair with `record_hit/1` once the caller knows which outcome should count.
  """
  def peek(bucket_key, max_requests, window_ms) do
    decide(bucket_key, max_requests - 1, window_ms, System.monotonic_time(:millisecond))
  end

  @doc "Unconditionally records one call against `bucket_key`, without any limit decision."
  def record_hit(bucket_key) do
    :ets.insert(@table, {bucket_key, System.monotonic_time(:millisecond), make_ref()})
    :ok
  end

  @doc "Forgets every recorded call in `bucket` (keys of the form `{bucket, _}`)."
  def reset(bucket) do
    :ets.match_delete(@table, {{bucket, :_}, :_, :_})
    :ok
  end

  # Allowed while at most `allowed` calls fall inside the window.
  defp decide(bucket_key, allowed, window_ms, now) do
    fresh = fresh_timestamps(bucket_key, now - window_ms)

    if length(fresh) > allowed do
      {:error, max(Enum.min(fresh) + window_ms - now, 0)}
    else
      :ok
    end
  end

  # `System.monotonic_time/1` is commonly negative, so cutoffs are compared
  # as-is rather than clamped at 0.
  defp fresh_timestamps(bucket_key, cutoff) do
    :ets.select(@table, [{{bucket_key, :"$1", :_}, [{:>, :"$1", cutoff}], [:"$1"]}])
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :duplicate_bag, write_concurrency: true])
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    cutoff = System.monotonic_time(:millisecond) - @max_key_age
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)
end
