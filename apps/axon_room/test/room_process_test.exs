defmodule AxonRoom.RoomProcessTest do
  @moduledoc """
  Direct `RoomProcess` GenServer tests not already covered by
  `AxonRoom.CreateRoomTest` (creation flow) or `AxonWeb.FederationFanoutTest`
  (which is specifically a regression test for `apply_remote_event/2`'s
  profile-change fan-out behavior).
  """

  use AxonRoom.DataCase, async: false

  alias AxonCore.UserStore
  alias AxonRoom.{CreateRoom, RoomProcess}

  defp new_user(prefix) do
    localpart = "#{prefix}_#{System.unique_integer([:positive])}"
    {:ok, %{user_id: user_id}} = UserStore.register(localpart, "Test1234!", server_name: "localhost")
    user_id
  end

  describe "state snapshotting (regression: NUL-byte separator broke every save)" do
    test "crossing the snapshot interval actually persists a loadable snapshot" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")

      # CreateRoom already sent ~6 state events; send enough more messages to
      # cross @snapshot_interval (100) and trigger the fire-and-forget save.
      for _ <- 1..100 do
        {:ok, _} = RoomProcess.send_event(room_id, creator, "m.room.message", %{"body" => "filler"})
      end

      # save_snapshot runs in a Task.Supervisor child; give it a moment.
      snapshot =
        Enum.reduce_while(1..50, nil, fn _, _ ->
          case AxonCore.EventStore.latest_snapshot(room_id) do
            nil -> Process.sleep(20); {:cont, nil}
            snap -> {:halt, snap}
          end
        end)

      refute is_nil(snapshot), "expected a snapshot to have been persisted"
      assert snapshot.after_stream_ordering > 0
      assert map_size(snapshot.state_map) > 0

      # And it must actually be usable on the read side: restarting the
      # RoomProcess (simulated by asking for state again — the point of the
      # snapshot is that a future init/1 would deserialize it successfully).
      current_state = RoomProcess.get_state_map(room_id)
      assert current_state[{"m.room.create", ""}]
    end
  end

  describe "send_event/5 — auth rejection" do
    test "a non-joined sender's event is rejected and never applied" do
      creator = new_user("alice")
      bob = new_user("bob")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")

      assert RoomProcess.send_event(room_id, bob, "m.room.message", %{"body" => "hi"}) ==
               {:error, :not_joined}

      # State untouched: no message event, position unchanged relative to a
      # fresh read.
      assert RoomProcess.get_state_event(room_id, "m.room.message", "") == nil
    end

    test "insufficient power to send a gated state event is rejected" do
      creator = new_user("alice")
      bob = new_user("bob")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost", preset: "public_chat")
      {:ok, _} = RoomProcess.send_event(room_id, bob, "m.room.member", %{"membership" => "join"}, state_key: bob)

      assert RoomProcess.send_event(room_id, bob, "m.room.name", %{"name" => "Hijacked"}, state_key: "") ==
               {:error, :insufficient_power}

      refute RoomProcess.get_state_event(room_id, "m.room.name", "")
    end
  end

  describe "apply_remote_event/2 — auth rejection" do
    test "a PDU that fails auth is rejected and not applied" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")
      {last_event_id, depth} = RoomProcess.get_position(room_id)

      bogus_pdu = %{
        "event_id" => "$bogus:remote.example",
        "type" => "m.room.message",
        "sender" => "@intruder:remote.example",
        "content" => %{"body" => "hi"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [],
        "origin" => "remote.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      assert RoomProcess.apply_remote_event(room_id, bogus_pdu) == {:error, :not_joined}
      assert RoomProcess.get_position(room_id) == {last_event_id, depth}
    end
  end

  describe "get_or_start/1" do
    test "concurrent lookups for the same room_id resolve to the same pid" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")

      pids =
        1..20
        |> Enum.map(fn _ -> Task.async(fn -> RoomProcess.get_or_start(room_id) end) end)
        |> Enum.map(&Task.await/1)
        |> Enum.map(fn {:ok, pid} -> pid end)
        |> Enum.uniq()

      assert length(pids) == 1
    end

    test "a nonexistent room_id fails to start" do
      assert {:error, _} = RoomProcess.get_or_start("!nonexistent_#{System.unique_integer([:positive])}:localhost")
    end
  end

  describe "state getters" do
    test "get_position/get_room_ctx/get_state_map reflect a sequence of sends" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost", name: "Room")

      {:ok, event_id} = RoomProcess.send_event(room_id, creator, "m.room.message", %{"body" => "hello"})

      {last_event_id, depth} = RoomProcess.get_position(room_id)
      assert last_event_id == event_id
      assert is_integer(depth)

      ctx = RoomProcess.get_room_ctx(room_id)
      assert ctx.room_id == room_id
      assert ctx.last_event_id == event_id
      assert ctx.depth == depth

      state_map = RoomProcess.get_state_map(room_id)
      assert state_map[{"m.room.name", ""}]["content"]["name"] == "Room"
      # A non-state message event never lands in current_state.
      refute Map.has_key?(state_map, {"m.room.message", ""})
    end

    test "get_state_event returns nil for a key that was never set" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")
      assert RoomProcess.get_state_event(room_id, "m.room.nonexistent", "") == nil
    end

    test "get_state returns the full list of current state events" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")

      assert {:ok, events} = RoomProcess.get_state(room_id)
      types = Enum.map(events, & &1["type"]) |> Enum.sort()
      assert "m.room.create" in types
      assert "m.room.member" in types
      assert "m.room.power_levels" in types
    end
  end
end
