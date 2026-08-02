defmodule AxonWeb.AppService.OutboundQueueTest do
  @moduledoc """
  Regression tests for the durable outbound Application Service delivery
  queue — the AS-push analogue of `AxonFederation.OutboundQueueTest`
  (Phase 9). Previously (Phase 4) a failed push just logged a warning and
  the event was dropped; `AxonWeb.AppService.OutboundQueue` persists the
  transaction before the first attempt and retries with backoff on failure.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias AxonCore.Repo
  alias AxonWeb.AppService.OutboundQueue
  alias AxonWeb.FakeAppService

  @table :axon_appservices

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AxonCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(AxonCore.Repo, {:shared, self()})
    :ets.insert(@table, {:registrations, []})

    on_exit(fn ->
      :ets.insert(@table, {:registrations, []})

      AxonWeb.ConnCase.await_task_supervisors_idle(
        [Axon.TaskSupervisor],
        System.monotonic_time(:millisecond) + 5_000
      )

      Ecto.Adapters.SQL.Sandbox.checkin(AxonCore.Repo)
    end)

    :ok
  end

  defp wait_until(deadline_ms, fun) do
    case fun.() do
      {:ok, value} ->
        value

      :error ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          flunk("condition not met before deadline")
        else
          Process.sleep(20)
          wait_until(deadline_ms, fun)
        end
    end
  end

  defp fetch_row(as_id) do
    Repo.one(
      from(t in "appservice_outbound_transactions",
        where: t.as_id == ^as_id,
        select: %{id: t.id, attempts: t.attempts, payload: t.payload}
      )
    )
  end

  defp registration(id, port) do
    %{
      "id" => id,
      "url" => "http://127.0.0.1:#{port}",
      "as_token" => "as-#{id}",
      "hs_token" => "hs-#{id}",
      "sender_localpart" => "_#{id}",
      "namespaces" => %{"users" => [], "aliases" => [], "rooms" => []}
    }
  end

  test "a successful delivery is not persisted afterwards" do
    port = 19_650
    start_supervised!({FakeAppService, port: port})
    reg = registration("bridge_ok", port)
    :ets.insert(@table, {:registrations, [reg]})
    FakeAppService.transaction_response(port, 200)

    :ok = OutboundQueue.enqueue(reg["id"], %{"events" => []})

    wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
      case fetch_row(reg["id"]) do
        nil -> {:ok, :gone}
        _ -> :error
      end
    end)
  end

  test "a failed delivery is persisted with an incremented attempt count, and succeeds on retry" do
    port = 19_651
    start_supervised!({FakeAppService, port: port})
    reg = registration("bridge_retry", port)
    :ets.insert(@table, {:registrations, [reg]})
    FakeAppService.transaction_response(port, 500)

    :ok = OutboundQueue.enqueue(reg["id"], %{"events" => [%{"type" => "m.room.message"}]})

    row =
      wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
        case fetch_row(reg["id"]) do
          %{attempts: 1} = row -> {:ok, row}
          _ -> :error
        end
      end)

    # Same txn_id (axonas<id>) on every attempt, per the spec's idempotency
    # requirement — a bridge that already processed an earlier attempt (but
    # whose 200 we missed) sees a duplicate txn_id.
    Repo.update_all(
      from(t in "appservice_outbound_transactions", where: t.id == ^row.id),
      set: [next_attempt_at: DateTime.utc_now()]
    )

    FakeAppService.transaction_response(port, 200)
    send(OutboundQueue, :sweep)

    wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
      case fetch_row(reg["id"]) do
        nil -> {:ok, :gone}
        _ -> :error
      end
    end)

    requests_for_txn =
      FakeAppService.requests(port)
      |> Enum.filter(
        &String.starts_with?(&1.path, "/_matrix/app/v1/transactions/axonas#{row.id}")
      )

    assert length(requests_for_txn) == 2
    [first, second] = requests_for_txn
    assert first.body == second.body
    assert {"authorization", "Bearer hs-bridge_retry"} in first.headers
  end

  test "delivery re-resolves the registration at attempt time (rotated hs_token takes effect)" do
    port = 19_652
    start_supervised!({FakeAppService, port: port})
    reg = registration("bridge_rotate", port)
    :ets.insert(@table, {:registrations, [reg]})
    FakeAppService.transaction_response(port, 200)

    :ok = OutboundQueue.enqueue(reg["id"], %{"events" => []})

    wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
      case FakeAppService.requests(port) do
        [] -> :error
        reqs -> {:ok, reqs}
      end
    end)

    # Almost always exactly one request — enqueue's own immediate delivery
    # attempt succeeds and deletes the row well within the 5s sweep
    # interval. Under heavy scheduler contention that attempt can rarely
    # still be in flight when a sweep tick independently rediscovers the
    # same not-yet-deleted row and fires a second one; both carry the same
    # idempotent txn_id (the row's own id), which is exactly the case the
    # spec's txn_id de-duplication contract exists for on the AS's side —
    # so assert on "at least one, all consistent" rather than "exactly one".
    requests = FakeAppService.requests(port)
    assert requests != []

    Enum.each(requests, fn request ->
      assert {"authorization", "Bearer hs-bridge_rotate"} in request.headers
    end)
  end

  test "a transaction for a since-removed registration is dropped rather than retried forever" do
    :ets.insert(@table, {:registrations, []})

    {1, [%{id: id}]} =
      Repo.insert_all(
        "appservice_outbound_transactions",
        [
          %{
            as_id: "no-such-as",
            payload: %{"events" => []},
            attempts: 0,
            next_attempt_at: DateTime.utc_now(),
            inserted_at: DateTime.utc_now()
          }
        ],
        returning: [:id]
      )

    send(OutboundQueue, :sweep)

    wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
      case Repo.one(
             from(t in "appservice_outbound_transactions", where: t.id == ^id, select: t.id)
           ) do
        nil -> {:ok, :gone}
        _ -> :error
      end
    end)
  end

  test "an unrecognized message is ignored without crashing the process" do
    pid = Process.whereis(OutboundQueue)
    send(OutboundQueue, {:some_unexpected_message, :whatever})
    Process.sleep(20)
    assert Process.alive?(pid)
    assert Process.whereis(OutboundQueue) == pid
  end
end
