defmodule AxonWeb.AppService.OutboundQueue do
  @moduledoc """
  Durable outbound Application Service delivery — the AS-push analogue of
  `AxonFederation.OutboundQueue` (Phase 9), reusing the same persist-then-
  retry-with-backoff shape rather than inventing a parallel one, since both
  are at-least-once HTTP delivery to a peer that might be briefly down.

  `enqueue/2` persists a `%{"events" => [...]}` transaction body for an AS
  (by registration `id`, not URL — resolved fresh at delivery time so a
  registration file edit, e.g. a rotated `hs_token` or moved `url`, takes
  effect on the next retry) and attempts delivery immediately. On failure it
  retries with exponential backoff (30s -> 1hr cap, giving up after 7 days,
  same envelope as the federation queue) instead of Phase 4's original
  behavior, which just logged a warning and dropped the event on any
  failure — meaning a bridge restarting or briefly unreachable silently
  missed whatever happened in its namespace during that window.

  The transaction's own row id is reused as the txn_id on every retry
  (`"axonas<id>"`), so a bridge that already processed an earlier attempt
  (but whose 200 we missed) sees a duplicate txn_id and can no-op per the
  spec's idempotency requirement, rather than double-processing.
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias AxonCore.Repo
  alias AxonWeb.AppService.{Client, Manager}

  @tick_interval :timer.seconds(5)
  @base_backoff_ms :timer.seconds(30)
  @max_backoff_ms :timer.hours(1)
  @max_age_ms :timer.hours(24) * 7
  @sweep_batch_size 100

  @concurrency_table :axon_appservice_outbound_concurrency
  @circuit_breaker_threshold 5
  @circuit_breaker_cooldown_ms :timer.seconds(60)

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Persists a transaction body for AS `as_id` and kicks off an immediate delivery attempt."
  def enqueue(as_id, payload) do
    now = DateTime.utc_now()

    {1, [%{id: id}]} =
      Repo.insert_all(
        "appservice_outbound_transactions",
        [
          %{
            as_id: as_id,
            payload: payload,
            attempts: 0,
            next_attempt_at: now,
            inserted_at: now
          }
        ],
        returning: [:id]
      )

    spawn_attempt(id, as_id)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@concurrency_table, [:named_table, :public, :set])
    Process.send_after(self(), :sweep, @tick_interval)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    due_rows =
      Repo.all(
        from(t in "appservice_outbound_transactions",
          where: t.next_attempt_at <= ^DateTime.utc_now(),
          select: %{id: t.id, as_id: t.as_id},
          limit: ^@sweep_batch_size
        )
      )

    Enum.each(due_rows, fn %{id: id, as_id: as_id} -> spawn_attempt(id, as_id) end)

    Process.send_after(self(), :sweep, @tick_interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private: delivery attempts (run in Task.Supervisor children, not the
  # GenServer, so a slow/hanging bridge can't block the sweep)
  # ---------------------------------------------------------------------------

  defp spawn_attempt(id, as_id) do
    cond do
      circuit_open?(as_id) ->
        :skipped

      not under_concurrency_cap?(as_id) ->
        :skipped

      true ->
        increment_inflight(as_id)

        Task.Supervisor.start_child(Axon.TaskSupervisor, fn ->
          try do
            attempt(id)
          after
            decrement_inflight(as_id)
          end
        end)
    end
  end

  defp attempt(id) do
    row =
      Repo.one(
        from(t in "appservice_outbound_transactions",
          where: t.id == ^id,
          select: %{
            id: t.id,
            as_id: t.as_id,
            payload: t.payload,
            attempts: t.attempts,
            inserted_at: t.inserted_at
          }
        )
      )

    case row do
      # Already delivered (or given up on) by a previous attempt.
      nil -> :ok
      row -> deliver(row)
    end
  end

  defp deliver(row) do
    case Manager.find_by_id(row.as_id) do
      :error ->
        # The registration no longer exists (removed from config since this
        # was enqueued) — nowhere left to deliver to, so give up rather than
        # retrying forever against an AS that can't come back.
        Logger.warning(
          "Dropping appservice transaction ##{row.id}: no registration #{inspect(row.as_id)}"
        )

        delete_row(row.id)

      {:ok, registration} ->
        txn_id = "axonas#{row.id}"

        case Client.push_transaction(registration, txn_id, row.payload) do
          :ok ->
            delete_row(row.id)
            reset_circuit(row.as_id)

          {:error, reason} ->
            record_failure(row.as_id)
            reschedule(row, reason)
        end
    end
  end

  defp delete_row(id) do
    Repo.delete_all(from(t in "appservice_outbound_transactions", where: t.id == ^id))
  end

  defp reschedule(row, reason) do
    attempts = row.attempts + 1
    age_ms = DateTime.diff(DateTime.utc_now(), to_utc_datetime(row.inserted_at), :millisecond)

    if age_ms > @max_age_ms do
      Logger.warning(
        "Giving up on appservice transaction ##{row.id} to #{row.as_id} " <>
          "after #{attempts} attempts over #{div(age_ms, 1000)}s: #{inspect(reason)}"
      )

      delete_row(row.id)
    else
      backoff_ms = min(round(@base_backoff_ms * :math.pow(2, attempts)), @max_backoff_ms)
      next_attempt_at = DateTime.add(DateTime.utc_now(), backoff_ms, :millisecond)

      Repo.update_all(
        from(t in "appservice_outbound_transactions", where: t.id == ^row.id),
        set: [attempts: attempts, next_attempt_at: next_attempt_at, last_error: inspect(reason)]
      )
    end
  end

  defp to_utc_datetime(%DateTime{} = dt), do: dt
  defp to_utc_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  # ---------------------------------------------------------------------------
  # Private: per-destination concurrency cap + circuit breaker — identical
  # idiom to AxonFederation.OutboundQueue's (see its moduledoc for why).
  # ---------------------------------------------------------------------------

  defp under_concurrency_cap?(as_id) do
    cap = Application.get_env(:axon_web, :appservice_outbound_concurrency_per_as, 5)
    current = :ets.lookup_element(@concurrency_table, {:inflight, as_id}, 2, 0)
    current < cap
  end

  defp increment_inflight(as_id) do
    :ets.update_counter(@concurrency_table, {:inflight, as_id}, {2, 1}, {{:inflight, as_id}, 0})
  end

  defp decrement_inflight(as_id) do
    :ets.update_counter(@concurrency_table, {:inflight, as_id}, {2, -1}, {{:inflight, as_id}, 0})
  end

  defp circuit_open?(as_id) do
    case :ets.lookup(@concurrency_table, {:circuit_open_until, as_id}) do
      [{_, open_until}] -> System.monotonic_time(:millisecond) < open_until
      [] -> false
    end
  end

  defp record_failure(as_id) do
    count =
      :ets.update_counter(@concurrency_table, {:failures, as_id}, {2, 1}, {{:failures, as_id}, 0})

    if count >= @circuit_breaker_threshold do
      open_until = System.monotonic_time(:millisecond) + @circuit_breaker_cooldown_ms
      :ets.insert(@concurrency_table, {{:circuit_open_until, as_id}, open_until})
      :ets.insert(@concurrency_table, {{:failures, as_id}, 0})
    end
  end

  defp reset_circuit(as_id) do
    :ets.insert(@concurrency_table, {{:failures, as_id}, 0})
    :ets.delete(@concurrency_table, {:circuit_open_until, as_id})
  end
end
