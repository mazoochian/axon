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
  the last `window_ms`, and records this call regardless of the outcome
  (a request that gets rejected still counts, so a client can't reset its
  own window for free by spamming past the limit).

  Returns `:ok` or `{:error, retry_after_ms}`.
  """
  def check(bucket_key, max_requests, window_ms) do
    case peek(bucket_key, max_requests, window_ms) do
      :ok ->
        record_hit(bucket_key)
        :ok

      error ->
        # Deliberately does NOT record_hit here: only an *accepted* call
        # adds a fresh timestamp (matching this function's pre-existing
        # behavior). A rejected call re-checking against an already-full
        # window must not keep pushing that window's start forward forever
        # — the oldest timestamps have to be free to age out on schedule,
        # or a client that keeps getting 429'd would never recover.
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
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms
    fresh = fresh_timestamps(bucket_key, cutoff)

    if length(fresh) >= max_requests do
      retry_after_ms = Enum.min(fresh) + window_ms - now
      {:error, max(retry_after_ms, 0)}
    else
      :ok
    end
  end

  @doc "Unconditionally records one call against `bucket_key`, without any limit decision."
  def record_hit(bucket_key) do
    now = System.monotonic_time(:millisecond)

    # `System.monotonic_time/1`'s reference point is arbitrary and commonly
    # negative (this BEAM's `now` values run in the hundreds of billions
    # negative) — a cutoff of `0` here would silently discard every real
    # entry rather than "not pruning at all", which is what this needs.
    existing =
      case :ets.lookup(@table, bucket_key) do
        [{^bucket_key, timestamps}] -> timestamps
        [] -> []
      end

    :ets.insert(@table, {bucket_key, [now | existing]})
    :ok
  end

  defp fresh_timestamps(bucket_key, cutoff) do
    case :ets.lookup(@table, bucket_key) do
      [{^bucket_key, timestamps}] -> Enum.filter(timestamps, &(&1 > cutoff))
      [] -> []
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
    cutoff = now - @max_key_age

    @table
    |> :ets.tab2list()
    |> Enum.each(fn {key, timestamps} ->
      case Enum.filter(timestamps, &(&1 > cutoff)) do
        [] -> :ets.delete(@table, key)
        fresh -> :ets.insert(@table, {key, fresh})
      end
    end)

    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)
end
