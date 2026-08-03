defmodule AxonFederation.BackfillTest do
  @moduledoc """
  Regression tests for `AxonFederation.Backfill.catch_up/3`'s
  `get_missing_events` request shape.

  Per the Server-Server API, `POST .../get_missing_events/{roomId}` takes
  `latest_events` — the event(s) whose ancestry the caller wants walked
  backwards from — and `earliest_events` — the boundary of what the caller
  already has, so the response doesn't walk further back than needed.

  `catch_up/3` used to build this request backwards: it passed the PDU's
  *missing* `prev_events` as `latest_events` (asking the origin to walk
  back from an event neither side has) and always sent an empty
  `earliest_events`. Any origin that validates the request shape — as
  Complement's `TestGetMissingEventsGapFilling` and `TestCorruptedAuthChain`
  both do — rejects or misbehaves on that malformed request, so the local
  gap is never actually closed. These tests pin the correct shape:
  `latest_events == [pdu's own event_id]`, `earliest_events == [our current
  head]`.
  """

  use AxonFederation.DataCase, async: false

  alias AxonCore.UserStore
  alias AxonFederation.{Backfill, FakeRemoteMatrixServer}
  alias AxonRoom.{CreateRoom, RoomProcess}

  @port 18_800
  @server_name "fake-backfill.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)

    localpart = "backfiller_#{System.unique_integer([:positive])}"

    {:ok, %{user_id: creator}} =
      UserStore.register(localpart, "Test1234!", server_name: "localhost")

    {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")
    {last_event_id, _depth} = RoomProcess.get_position(room_id)

    %{room_id: room_id, last_event_id: last_event_id}
  end

  defp gme_requests(port) do
    FakeRemoteMatrixServer.requests(port)
    |> Enum.filter(&(&1.path =~ "get_missing_events"))
  end

  test "latest_events is the received PDU's own id, not its missing prev_event", %{
    room_id: room_id
  } do
    FakeRemoteMatrixServer.put_response(
      @port,
      {"POST", ~r{^/_matrix/federation/v1/get_missing_events/}},
      200,
      %{"events" => []}
    )

    missing_prev_id = "$never-sent-#{System.unique_integer([:positive])}"

    pdu = %{
      "event_id" => "$incoming_#{System.unique_integer([:positive])}",
      "room_id" => room_id,
      "prev_events" => [missing_prev_id]
    }

    Backfill.catch_up(room_id, @server_name, pdu)

    [request] = gme_requests(@port)

    assert request.body["latest_events"] == [pdu["event_id"]]
    refute request.body["latest_events"] == [missing_prev_id]
  end

  test "earliest_events is our own current head, not empty", %{
    room_id: room_id,
    last_event_id: last_event_id
  } do
    FakeRemoteMatrixServer.put_response(
      @port,
      {"POST", ~r{^/_matrix/federation/v1/get_missing_events/}},
      200,
      %{"events" => []}
    )

    pdu = %{
      "event_id" => "$incoming_#{System.unique_integer([:positive])}",
      "room_id" => room_id,
      "prev_events" => ["$never-sent-#{System.unique_integer([:positive])}"]
    }

    Backfill.catch_up(room_id, @server_name, pdu)

    [request] = gme_requests(@port)

    assert request.body["earliest_events"] == [last_event_id]
  end

  test "a gap fully closed by get_missing_events does not also hit /backfill", %{
    room_id: room_id
  } do
    missing_prev_id = "$never-sent-#{System.unique_integer([:positive])}"

    gap_filler =
      FakeRemoteMatrixServer.sign_event(@port, %{
        "event_id" => missing_prev_id,
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => "@ghost:#{@server_name}",
        "content" => %{"body" => "filler"},
        "depth" => 1,
        "origin" => @server_name,
        "origin_server_ts" => System.os_time(:millisecond),
        "auth_events" => [],
        "prev_events" => [],
        "hashes" => %{"sha256" => "x"}
      })

    FakeRemoteMatrixServer.put_response(
      @port,
      {"POST", ~r{^/_matrix/federation/v1/get_missing_events/}},
      200,
      %{"events" => [gap_filler]}
    )

    pdu = %{
      "event_id" => "$incoming_#{System.unique_integer([:positive])}",
      "room_id" => room_id,
      "prev_events" => [missing_prev_id]
    }

    Backfill.catch_up(room_id, @server_name, pdu)

    backfill_requests =
      FakeRemoteMatrixServer.requests(@port)
      |> Enum.filter(&(&1.path =~ ~r{^/_matrix/federation/v1/backfill/}))

    assert backfill_requests == []

    # And the fetched event actually landed (stored, even if rejected —
    # the point here is just that catch_up didn't bail out early).
    assert {:ok, _} = AxonCore.EventStore.get_event(missing_prev_id)
  end
end
