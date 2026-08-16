defmodule AxonFederation.OutboundQueueTest do
  @moduledoc """
  Regression tests for Phase 9's durable outbound federation delivery.

  Previously a failed outbound delivery (PDU fan-out or EDU relay) just
  logged a warning and was dropped — a remote server being briefly
  unreachable silently lost whatever was sent to it during that window.
  `AxonFederation.OutboundQueue` persists the transaction before the first
  attempt and retries with backoff on failure.
  """

  use AxonFederation.DataCase, async: false

  import ExUnit.CaptureLog

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache, OutboundQueue}

  @port 18_720
  @server_name "fake-outboundq.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
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

  defp fetch_row(destination) do
    Repo.one(
      from(t in "federation_outbound_transactions",
        where: t.destination == ^destination,
        select: %{id: t.id, attempts: t.attempts, payload: t.payload}
      )
    )
  end

  # Schemaless selects on a utc_datetime_usec column (backed by a
  # timezone-less `timestamp` column) come back as NaiveDateTime, since
  # there's no schema field type annotation to trigger Ecto's DateTime
  # cast — same caveat OutboundQueue.to_utc_datetime/1 itself works around.
  defp fetch_next_attempt_at(id) do
    Repo.one(
      from(t in "federation_outbound_transactions",
        where: t.id == ^id,
        select: t.next_attempt_at
      )
    )
    |> DateTime.from_naive!("Etc/UTC")
  end

  test "a successful delivery is not persisted afterwards" do
    FakeRemoteMatrixServer.put_response(
      @port,
      {"PUT", ~r{^/_matrix/federation/v1/send/}},
      200,
      %{"pdus" => %{}}
    )

    :ok = OutboundQueue.enqueue(@server_name, %{"pdus" => [], "edus" => []})

    wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
      case fetch_row(@server_name) do
        nil -> {:ok, :gone}
        _ -> :error
      end
    end)
  end

  test "a failed delivery is persisted with an incremented attempt count, and succeeds on retry" do
    FakeRemoteMatrixServer.put_response(
      @port,
      {"PUT", ~r{^/_matrix/federation/v1/send/}},
      500,
      %{"errcode" => "M_UNKNOWN", "error" => "simulated failure"}
    )

    :ok =
      OutboundQueue.enqueue(@server_name, %{"pdus" => [], "edus" => [%{"edu_type" => "m.test"}]})

    row =
      wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
        case fetch_row(@server_name) do
          %{attempts: 1} = row -> {:ok, row}
          _ -> :error
        end
      end)

    assert row.payload["edus"] == [%{"edu_type" => "m.test"}]

    # Simulate the backoff having elapsed and the remote server recovering,
    # then trigger a sweep directly rather than waiting out the real backoff.
    Repo.update_all(
      from(t in "federation_outbound_transactions", where: t.id == ^row.id),
      set: [next_attempt_at: DateTime.utc_now()]
    )

    FakeRemoteMatrixServer.put_response(
      @port,
      {"PUT", ~r{^/_matrix/federation/v1/send/}},
      200,
      %{"pdus" => %{}}
    )

    send(OutboundQueue, :sweep)

    wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
      case fetch_row(@server_name) do
        nil -> {:ok, :gone}
        _ -> :error
      end
    end)

    # Same txn_id (axonq<id>) on every attempt, so a remote server that
    # already processed an earlier try can respond idempotently — expect
    # both the original failed attempt and the successful retry here.
    requests_for_txn =
      FakeRemoteMatrixServer.requests(@port)
      |> Enum.filter(&String.starts_with?(&1.path, "/_matrix/federation/v1/send/axonq#{row.id}"))

    assert length(requests_for_txn) == 2
    assert List.last(requests_for_txn).body["edus"] == [%{"edu_type" => "m.test"}]
  end

  # Regression: reschedule/2 used `attempts` (already incremented to 1 on
  # the first failure) directly as the exponent, so the delay after the
  # *first* failure was base*2^1 instead of base*2^0 — one full doubling
  # too long from the very first retry onward. Combined with the 30s base
  # this was tuned from, a destination that failed exactly once (a brief
  # blip, not a real outage) waited a full 60s before even being eligible
  # for retry — long enough on its own to blow past Complement's
  # ~30-50s MustSyncUntil budgets in
  # TestToDeviceMessagesOverFederation's interrupted_connectivity/
  # stopped_server subtests. After one failure, the next attempt must be
  # scheduled ~base (now 5s), not ~2x base.
  test "the delay after a single failure is ~1x the base backoff, not ~2x" do
    FakeRemoteMatrixServer.put_response(
      @port,
      {"PUT", ~r{^/_matrix/federation/v1/send/}},
      500,
      %{"errcode" => "M_UNKNOWN", "error" => "simulated failure"}
    )

    before = DateTime.utc_now()

    :ok = OutboundQueue.enqueue(@server_name, %{"pdus" => [], "edus" => []})

    row =
      wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
        case fetch_row(@server_name) do
          %{attempts: 1} = row -> {:ok, row}
          _ -> :error
        end
      end)

    next_attempt_at = fetch_next_attempt_at(row.id)
    delay_ms = DateTime.diff(next_attempt_at, before, :millisecond)

    # ~5s expected (base backoff after one failure); would be ~60s under
    # the old 30s-base/off-by-one-exponent bug this guards against.
    assert delay_ms > 0 and delay_ms < 15_000,
           "expected the next attempt to be scheduled ~5s out, got #{delay_ms}ms"
  end

  test "an unrecognized message is ignored without crashing the process" do
    pid = Process.whereis(OutboundQueue)
    send(OutboundQueue, {:some_unexpected_message, :whatever})
    Process.sleep(20)
    assert Process.alive?(pid)
    assert Process.whereis(OutboundQueue) == pid
  end

  test "a transaction older than the max retry age is given up on and removed instead of rescheduled" do
    FakeRemoteMatrixServer.put_response(
      @port,
      {"PUT", ~r{^/_matrix/federation/v1/send/}},
      500,
      %{"errcode" => "M_UNKNOWN", "error" => "simulated failure"}
    )

    eight_days_ago = DateTime.add(DateTime.utc_now(), -8 * 24 * 3600, :second)

    {1, [%{id: id}]} =
      Repo.insert_all(
        "federation_outbound_transactions",
        [
          %{
            destination: @server_name,
            payload: %{"pdus" => [], "edus" => []},
            attempts: 5,
            next_attempt_at: DateTime.utc_now(),
            inserted_at: eight_days_ago
          }
        ],
        returning: [:id]
      )

    log =
      capture_log(fn ->
        send(OutboundQueue, :sweep)

        wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
          case Repo.one(
                 from(t in "federation_outbound_transactions", where: t.id == ^id, select: t.id)
               ) do
            nil -> {:ok, :gone}
            _ -> :error
          end
        end)
      end)

    assert log =~ "Giving up on federation transaction ##{id}"
  end
end
