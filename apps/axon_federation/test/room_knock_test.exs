defmodule AxonFederation.RoomKnockTest do
  @moduledoc """
  Tests `AxonFederation.RoomKnock.knock_via_federation/4` — mirrors
  `AxonFederation.RoomJoinTest`'s pattern for the make_knock -> sign ->
  send_knock flow (MSC2403).
  """

  use AxonFederation.DataCase, async: false

  import ExUnit.CaptureLog

  alias AxonCore.{EventStore, UserStore}
  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache, RoomKnock}

  @port 18_750
  @server_name "fake-roomknock.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)

    localpart = "knocker_#{System.unique_integer([:positive])}"

    {:ok, %{user_id: user_id}} =
      UserStore.register(localpart, "Test1234!", server_name: "localhost")

    %{user_id: user_id}
  end

  defp remote_room_id, do: "!remote_#{System.unique_integer([:positive])}:#{@server_name}"

  test "happy path: knocks on a remote room and records the local knock + preview state", %{
    user_id: user_id
  } do
    room_id = remote_room_id()

    FakeRemoteMatrixServer.make_knock_response(@port, room_id, user_id, "10")

    preview = [
      %{
        "type" => "m.room.name",
        "state_key" => "",
        "sender" => "@owner:#{@server_name}",
        "content" => %{"name" => "Cool Room"}
      }
    ]

    FakeRemoteMatrixServer.send_knock_response(@port, preview)

    assert RoomKnock.knock_via_federation(room_id, user_id, [@server_name], "let me in") ==
             {:ok, room_id}

    assert EventStore.get_membership(room_id, user_id) == {:ok, "knock"}
    assert EventStore.get_knock_preview_state(room_id, user_id) == preview
  end

  test "the reason field round-trips into the signed knock event's content", %{user_id: user_id} do
    room_id = remote_room_id()
    FakeRemoteMatrixServer.make_knock_response(@port, room_id, user_id, "10")
    FakeRemoteMatrixServer.send_knock_response(@port, [])

    {:ok, ^room_id} =
      RoomKnock.knock_via_federation(room_id, user_id, [@server_name], "please let me in")

    [%{body: sent_knock_event}] =
      FakeRemoteMatrixServer.requests(@port)
      |> Enum.filter(&String.contains?(&1.path, "send_knock"))

    assert sent_knock_event["content"]["reason"] == "please let me in"
    assert sent_knock_event["content"]["membership"] == "knock"
  end

  test "a nil reason omits the reason field entirely", %{user_id: user_id} do
    room_id = remote_room_id()
    FakeRemoteMatrixServer.make_knock_response(@port, room_id, user_id, "10")
    FakeRemoteMatrixServer.send_knock_response(@port, [])

    {:ok, ^room_id} = RoomKnock.knock_via_federation(room_id, user_id, [@server_name], nil)

    [%{body: sent_knock_event}] =
      FakeRemoteMatrixServer.requests(@port)
      |> Enum.filter(&String.contains?(&1.path, "send_knock"))

    refute Map.has_key?(sent_knock_event["content"], "reason")
  end

  test "falls back to the next server in via_servers when the first fails", %{user_id: user_id} do
    room_id = remote_room_id()
    bad_server = "unreachable-knock-#{System.unique_integer([:positive])}.test"

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}",
      bad_server => "http://127.0.0.1:1"
    })

    FakeRemoteMatrixServer.make_knock_response(@port, room_id, user_id, "10")
    FakeRemoteMatrixServer.send_knock_response(@port, [])

    assert RoomKnock.knock_via_federation(room_id, user_id, [bad_server, @server_name], nil) ==
             {:ok, room_id}
  end

  test "returns :all_servers_failed when every server fails", %{user_id: user_id} do
    room_id = remote_room_id()

    assert RoomKnock.knock_via_federation(room_id, user_id, [@server_name], nil) ==
             {:error, :all_servers_failed}
  end

  test "a malformed make_knock response is a failure, not a crash", %{user_id: user_id} do
    room_id = remote_room_id()

    FakeRemoteMatrixServer.put_response(
      @port,
      {"GET", ~r{^/_matrix/federation/v1/make_knock/}},
      200,
      %{"nope" => true}
    )

    assert RoomKnock.knock_via_federation(room_id, user_id, [@server_name], nil) ==
             {:error, :all_servers_failed}
  end

  test "a make_knock response with no room_version defaults to room version 11", %{
    user_id: user_id
  } do
    room_id = remote_room_id()

    template = %{
      "type" => "m.room.member",
      "room_id" => room_id,
      "sender" => user_id,
      "state_key" => user_id,
      "content" => %{"membership" => "knock"},
      "depth" => 1,
      "prev_events" => [],
      "auth_events" => [],
      "origin" => @server_name
    }

    FakeRemoteMatrixServer.put_response(
      @port,
      {"GET", ~r{^/_matrix/federation/v1/make_knock/}},
      200,
      %{"event" => template}
    )

    FakeRemoteMatrixServer.send_knock_response(@port, [])

    assert RoomKnock.knock_via_federation(room_id, user_id, [@server_name], nil) == {:ok, room_id}

    assert Repo.one(
             Ecto.Query.from(r in "rooms", where: r.room_id == ^room_id, select: r.version)
           ) == "11"
  end

  test "a knock event that fails to insert (e.g. missing room_id) is logged, but the flow still completes",
       %{
         user_id: user_id
       } do
    room_id = remote_room_id()

    template = %{
      "type" => "m.room.member",
      "sender" => user_id,
      "state_key" => user_id,
      "content" => %{"membership" => "knock"},
      "depth" => 1,
      "prev_events" => [],
      "auth_events" => [],
      "origin" => @server_name
    }

    FakeRemoteMatrixServer.put_response(
      @port,
      {"GET", ~r{^/_matrix/federation/v1/make_knock/}},
      200,
      %{"event" => template, "room_version" => "10"}
    )

    FakeRemoteMatrixServer.send_knock_response(@port, [])

    log =
      capture_log(fn ->
        assert RoomKnock.knock_via_federation(room_id, user_id, [@server_name], nil) ==
                 {:ok, room_id}
      end)

    assert log =~ "Failed to insert knock event"
  end
end
