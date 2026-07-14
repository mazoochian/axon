defmodule AxonFederation.OutboundQueue do
  @moduledoc """
  Durable outbound federation delivery.

  `enqueue/2` persists a transaction body for a destination server and
  attempts delivery immediately (so the common case — the remote server is
  up — has no added latency). If that attempt fails, a periodic sweep
  retries it with exponential backoff until it succeeds or it's given up on
  (see `@max_age_ms`), instead of the previous behavior where a failed
  delivery just logged a warning and was silently dropped — meaning a
  remote server being briefly unreachable lost whatever room events or
  to-device/EDU traffic was sent to it during that window.

  The transaction's own row id is reused as the txn_id on every retry
  (`"axonq<id>"`), so a remote server that already processed an earlier
  attempt (but whose 200 response we missed) sees a duplicate txn_id and
  replies idempotently per the federation spec, rather than reprocessing.
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias AxonCore.Repo
  alias AxonFederation.HttpClient

  @tick_interval :timer.seconds(5)
  @base_backoff_ms :timer.seconds(30)
  @max_backoff_ms :timer.hours(1)
  @max_age_ms :timer.hours(24) * 7
  @sweep_batch_size 100

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Persists a `%{"pdus" => [...], "edus" => [...], ...}` transaction body for
  `destination` and kicks off an immediate delivery attempt.
  """
  def enqueue(destination, payload) do
    now = DateTime.utc_now()

    {1, [%{id: id}]} =
      Repo.insert_all(
        "federation_outbound_transactions",
        [
          %{
            destination: destination,
            payload: payload,
            attempts: 0,
            next_attempt_at: now,
            inserted_at: now
          }
        ],
        returning: [:id]
      )

    spawn_attempt(id)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok) do
    Process.send_after(self(), :sweep, @tick_interval)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    due_ids =
      Repo.all(
        from(t in "federation_outbound_transactions",
          where: t.next_attempt_at <= ^DateTime.utc_now(),
          select: t.id,
          limit: ^@sweep_batch_size
        )
      )

    Enum.each(due_ids, &spawn_attempt/1)

    Process.send_after(self(), :sweep, @tick_interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private: delivery attempts (run in Task.Supervisor children, not the
  # GenServer, so a slow/hanging remote server can't block the sweep)
  # ---------------------------------------------------------------------------

  defp spawn_attempt(id) do
    Task.Supervisor.start_child(AxonFederation.TaskSupervisor, fn -> attempt(id) end)
  end

  defp attempt(id) do
    row =
      Repo.one(
        from(t in "federation_outbound_transactions",
          where: t.id == ^id,
          select: %{
            id: t.id,
            destination: t.destination,
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
    txn_id = "axonq#{row.id}"

    case HttpClient.put(row.destination, "/_matrix/federation/v1/send/#{txn_id}", row.payload) do
      {:ok, _} ->
        Repo.delete_all(from(t in "federation_outbound_transactions", where: t.id == ^row.id))

      {:error, reason} ->
        reschedule(row, reason)
    end
  end

  defp reschedule(row, reason) do
    attempts = row.attempts + 1
    age_ms = DateTime.diff(DateTime.utc_now(), to_utc_datetime(row.inserted_at), :millisecond)

    if age_ms > @max_age_ms do
      Logger.warning(
        "Giving up on federation transaction ##{row.id} to #{row.destination} " <>
          "after #{attempts} attempts over #{div(age_ms, 1000)}s: #{inspect(reason)}"
      )

      Repo.delete_all(from(t in "federation_outbound_transactions", where: t.id == ^row.id))
    else
      backoff_ms = min(round(@base_backoff_ms * :math.pow(2, attempts)), @max_backoff_ms)
      next_attempt_at = DateTime.add(DateTime.utc_now(), backoff_ms, :millisecond)

      Repo.update_all(
        from(t in "federation_outbound_transactions", where: t.id == ^row.id),
        set: [attempts: attempts, next_attempt_at: next_attempt_at, last_error: inspect(reason)]
      )
    end
  end

  # Schemaless selects on a `utc_datetime_usec` column (backed by a
  # timezone-less `timestamp` column) come back as NaiveDateTime, since
  # there's no schema field type annotation to trigger Ecto's DateTime cast.
  defp to_utc_datetime(%DateTime{} = dt), do: dt
  defp to_utc_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
end
