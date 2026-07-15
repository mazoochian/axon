defmodule AxonFederation.RoomJoinTest do
  @moduledoc """
  Tests `AxonFederation.RoomJoin.join_via_federation/3` — the outbound
  make_join -> sign -> send_join flow — against a real `FakeRemoteMatrixServer`.
  """

  use AxonFederation.DataCase, async: false

  import ExUnit.CaptureLog

  alias AxonCore.UserStore
  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache, RoomJoin}

  @port 18_700
  @server_name "fake-roomjoin.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)

    localpart = "joiner_#{System.unique_integer([:positive])}"

    {:ok, %{user_id: user_id}} =
      UserStore.register(localpart, "Test1234!", server_name: "localhost")

    %{user_id: user_id}
  end

  defp remote_room_id, do: "!remote_#{System.unique_integer([:positive])}:#{@server_name}"

  defp remote_state_events(room_id) do
    create =
      FakeRemoteMatrixServer.sign_event(@port, %{
        "event_id" => "$create_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.create",
        "state_key" => "",
        "sender" => "@remoteowner:#{@server_name}",
        "content" => %{"creator" => "@remoteowner:#{@server_name}", "room_version" => "10"},
        "depth" => 1,
        "origin" => @server_name,
        "origin_server_ts" => System.os_time(:millisecond),
        "auth_events" => [],
        "prev_events" => [],
        "hashes" => %{"sha256" => "x"}
      })

    owner_join =
      FakeRemoteMatrixServer.sign_event(@port, %{
        "event_id" => "$ownerjoin_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.member",
        "state_key" => "@remoteowner:#{@server_name}",
        "sender" => "@remoteowner:#{@server_name}",
        "content" => %{"membership" => "join"},
        "depth" => 2,
        "origin" => @server_name,
        "origin_server_ts" => System.os_time(:millisecond),
        "auth_events" => [],
        "prev_events" => [],
        "hashes" => %{"sha256" => "x"}
      })

    join_rules =
      FakeRemoteMatrixServer.sign_event(@port, %{
        "event_id" => "$jr_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.join_rules",
        "state_key" => "",
        "sender" => "@remoteowner:#{@server_name}",
        "content" => %{"join_rule" => "public"},
        "depth" => 3,
        "origin" => @server_name,
        "origin_server_ts" => System.os_time(:millisecond),
        "auth_events" => [],
        "prev_events" => [],
        "hashes" => %{"sha256" => "x"}
      })

    [create, owner_join, join_rules]
  end

  test "happy path: joins a remote room and imports its state", %{user_id: user_id} do
    room_id = remote_room_id()

    FakeRemoteMatrixServer.make_join_response(@port, room_id, user_id, "10")
    FakeRemoteMatrixServer.send_join_response(@port, remote_state_events(room_id), [])

    assert RoomJoin.join_via_federation(room_id, user_id, [@server_name]) == {:ok, room_id}

    assert {:ok, state_events} = AxonRoom.RoomProcess.get_state(room_id)
    types = Enum.map(state_events, & &1["type"])
    assert "m.room.create" in types
    assert "m.room.member" in types
  end

  test "the signed join event carries the sender's user_id and membership join", %{
    user_id: user_id
  } do
    room_id = remote_room_id()
    FakeRemoteMatrixServer.make_join_response(@port, room_id, user_id, "10")
    FakeRemoteMatrixServer.send_join_response(@port, remote_state_events(room_id), [])

    {:ok, ^room_id} = RoomJoin.join_via_federation(room_id, user_id, [@server_name])

    [%{body: sent_join_event}] =
      FakeRemoteMatrixServer.requests(@port)
      |> Enum.filter(&String.contains?(&1.path, "send_join"))

    assert sent_join_event["sender"] == user_id
    assert sent_join_event["state_key"] == user_id
    assert sent_join_event["content"]["membership"] == "join"
  end

  test "a restricted-join authoriser stamp in the make_join template survives into the signed event",
       %{user_id: user_id} do
    room_id = remote_room_id()

    FakeRemoteMatrixServer.make_join_response(@port, room_id, user_id, "10", %{
      "join_authorised_via_users_server" => "@authoriser:#{@server_name}"
    })

    FakeRemoteMatrixServer.send_join_response(@port, remote_state_events(room_id), [])

    {:ok, ^room_id} = RoomJoin.join_via_federation(room_id, user_id, [@server_name])

    [%{body: sent_join_event}] =
      FakeRemoteMatrixServer.requests(@port)
      |> Enum.filter(&String.contains?(&1.path, "send_join"))

    assert sent_join_event["content"]["join_authorised_via_users_server"] ==
             "@authoriser:#{@server_name}"
  end

  test "falls back to the next server in via_servers when the first fails", %{user_id: user_id} do
    room_id = remote_room_id()
    bad_server = "unreachable-#{System.unique_integer([:positive])}.test"

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}",
      bad_server => "http://127.0.0.1:1"
    })

    FakeRemoteMatrixServer.make_join_response(@port, room_id, user_id, "10")
    FakeRemoteMatrixServer.send_join_response(@port, remote_state_events(room_id), [])

    assert RoomJoin.join_via_federation(room_id, user_id, [bad_server, @server_name]) ==
             {:ok, room_id}
  end

  test "returns :all_servers_failed when every server in via_servers fails", %{user_id: user_id} do
    room_id = remote_room_id()
    # No canned make_join response registered -> fake server 404s.
    assert RoomJoin.join_via_federation(room_id, user_id, [@server_name]) ==
             {:error, :all_servers_failed}
  end

  test "a malformed make_join response (no event) is treated as a failure, not a crash", %{
    user_id: user_id
  } do
    room_id = remote_room_id()

    FakeRemoteMatrixServer.put_response(
      @port,
      {"GET", ~r{^/_matrix/federation/v1/make_join/}},
      200,
      %{"unexpected" => "shape"}
    )

    assert RoomJoin.join_via_federation(room_id, user_id, [@server_name]) ==
             {:error, :all_servers_failed}
  end

  test "a make_join response with no room_version defaults to room version 11", %{
    user_id: user_id
  } do
    room_id = remote_room_id()

    template = %{
      "type" => "m.room.member",
      "room_id" => room_id,
      "sender" => user_id,
      "state_key" => user_id,
      "content" => %{"membership" => "join"},
      "depth" => 1,
      "prev_events" => [],
      "auth_events" => [],
      "origin" => @server_name
    }

    FakeRemoteMatrixServer.put_response(
      @port,
      {"GET", ~r{^/_matrix/federation/v1/make_join/}},
      200,
      %{"event" => template}
    )

    FakeRemoteMatrixServer.send_join_response(@port, remote_state_events(room_id), [])

    assert RoomJoin.join_via_federation(room_id, user_id, [@server_name]) == {:ok, room_id}

    assert Repo.one(
             Ecto.Query.from(r in "rooms", where: r.room_id == ^room_id, select: r.version)
           ) == "11"
  end

  test "a state event that fails to insert (e.g. missing room_id) is logged and skipped, not a crash",
       %{
         user_id: user_id
       } do
    room_id = remote_room_id()
    FakeRemoteMatrixServer.make_join_response(@port, room_id, user_id, "10")

    broken_state_event =
      FakeRemoteMatrixServer.sign_event(@port, %{
        "event_id" => "$broken_#{System.unique_integer([:positive])}",
        "type" => "m.room.topic",
        "state_key" => "",
        "sender" => "@remoteowner:#{@server_name}",
        "content" => %{"topic" => "no room_id on this one"},
        "depth" => 2,
        "origin" => @server_name,
        "origin_server_ts" => System.os_time(:millisecond),
        "auth_events" => [],
        "prev_events" => [],
        "hashes" => %{"sha256" => "x"}
      })

    FakeRemoteMatrixServer.send_join_response(
      @port,
      remote_state_events(room_id) ++ [broken_state_event],
      []
    )

    log =
      capture_log(fn ->
        assert RoomJoin.join_via_federation(room_id, user_id, [@server_name]) == {:ok, room_id}
      end)

    assert log =~ "Failed to insert event"
  end

  test "a join event that itself fails to insert (missing room_id in the make_join template) is logged, not a crash",
       %{user_id: user_id} do
    room_id = remote_room_id()

    # Deliberately omit "room_id" from the template — build_and_sign_join
    # carries it forward as-is, so the final signed join event will lack it
    # too, failing changeset validation at insert time.
    template = %{
      "type" => "m.room.member",
      "sender" => user_id,
      "state_key" => user_id,
      "content" => %{"membership" => "join"},
      "depth" => 1,
      "prev_events" => [],
      "auth_events" => [],
      "origin" => @server_name
    }

    FakeRemoteMatrixServer.put_response(
      @port,
      {"GET", ~r{^/_matrix/federation/v1/make_join/}},
      200,
      %{"event" => template, "room_version" => "10"}
    )

    FakeRemoteMatrixServer.send_join_response(@port, remote_state_events(room_id), [])

    log =
      capture_log(fn ->
        assert RoomJoin.join_via_federation(room_id, user_id, [@server_name]) == {:ok, room_id}
      end)

    assert log =~ "Failed to insert join event"
  end
end
