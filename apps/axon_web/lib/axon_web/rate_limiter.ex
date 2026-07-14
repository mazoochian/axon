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
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms

    fresh =
      case :ets.lookup(@table, bucket_key) do
        [{^bucket_key, timestamps}] -> Enum.filter(timestamps, &(&1 > cutoff))
        [] -> []
      end

    if length(fresh) >= max_requests do
      retry_after_ms = Enum.min(fresh) + window_ms - now
      :ets.insert(@table, {bucket_key, fresh})
      {:error, max(retry_after_ms, 0)}
    else
      :ets.insert(@table, {bucket_key, [now | fresh]})
      :ok
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
