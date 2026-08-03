defmodule AxonFederation.RoomJoinV12Test do
  @moduledoc """
  Regression coverage for a real bug found by Complement's
  `TestComplementCanCreateValidV12Rooms`: joining a room that only exists
  on a remote server (never seen locally before) failed with
  `{:error, :all_servers_failed}` for *every* room version 12 room,
  because `RoomJoin`/`RoomKnock`'s hardcoded `@supported_versions` list
  advertised via the outbound `make_join`/`make_knock` `?ver=` query
  params stopped at "11" — room v12 support (Phase 12) never updated it.
  A spec-compliant remote server picks a room version from the
  requester's advertised `ver` list and 400s if the room's actual
  version isn't in it, so a v12 room could never be joined or knocked on
  via federation despite axon fully supporting v12 locally.

  `FakeRemoteMatrixServer.make_join_response/4` doesn't itself validate
  `ver=` (so this wouldn't have failed loudly against the fake even with
  the bug) — these tests instead assert directly on the outbound request
  the fake captured, which is the actual thing that was wrong.
  """

  use AxonFederation.DataCase, async: false

  alias AxonCore.UserStore
  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache, RoomJoin, RoomKnock}

  @port 18_712
  @server_name "fake-roomjoinv12.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)

    localpart = "v12joiner_#{System.unique_integer([:positive])}"

    {:ok, %{user_id: user_id}} =
      UserStore.register(localpart, "Test1234!", server_name: "localhost")

    %{user_id: user_id}
  end

  defp remote_room_id, do: "!v12remote_#{System.unique_integer([:positive])}:#{@server_name}"

  defp query_for(port, path_substring) do
    FakeRemoteMatrixServer.requests(port)
    |> Enum.find(&String.contains?(&1.path, path_substring))
    |> Map.fetch!(:query_string)
  end

  test "joining a remote room advertises support for room version 12", %{user_id: user_id} do
    room_id = remote_room_id()

    FakeRemoteMatrixServer.make_join_response(@port, room_id, user_id, "12")
    FakeRemoteMatrixServer.send_join_response(@port, [], [])

    assert RoomJoin.join_via_federation(room_id, user_id, [@server_name]) == {:ok, room_id}

    query = query_for(@port, "make_join")
    assert query =~ "ver=12"
  end

  test "knocking a remote room advertises support for room version 12", %{user_id: user_id} do
    room_id = remote_room_id()

    FakeRemoteMatrixServer.make_knock_response(@port, room_id, user_id, "12")
    FakeRemoteMatrixServer.send_knock_response(@port, %{})

    assert RoomKnock.knock_via_federation(room_id, user_id, [@server_name], nil) ==
             {:ok, room_id}

    query = query_for(@port, "make_knock")
    assert query =~ "ver=12"
  end
end
