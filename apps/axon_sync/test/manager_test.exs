defmodule AxonSync.ManagerTest do
  @moduledoc """
  Tests `AxonSync.Manager.wait_for_events/3` — the long-poll `/sync` waiter.
  Note: the actual wait loop runs in the *caller's* process via `receive`
  (not routed through the `AxonSync.Manager` GenServer itself), so these
  tests drive it directly and simulate `RoomProcess`'s PubSub broadcast by
  hand (axon_sync doesn't depend on axon_room, so it can't use the real
  GenServer here).
  """

  use AxonSync.DataCase, async: false

  alias AxonCore.{EventStore, UserStore}
  alias AxonSync.Manager

  @pubsub Axon.PubSub

  defp new_user(prefix) do
    localpart = "#{prefix}_#{System.unique_integer([:positive])}"

    {:ok, %{user_id: user_id}} =
      UserStore.register(localpart, "Test1234!", server_name: "localhost")

    user_id
  end

  defp create_room_and_join(user_id) do
    room_id = "!room_#{System.unique_integer([:positive])}:localhost"
    {:ok, _} = EventStore.insert_room(room_id, user_id, "10", false)

    {:ok, _} =
      EventStore.insert_event(
        %{
          "event_id" => "$#{System.unique_integer([:positive])}",
          "room_id" => room_id,
          "sender" => user_id,
          "type" => "m.room.member",
          "state_key" => user_id,
          "content" => %{"membership" => "join"},
          "origin_server_ts" => System.os_time(:millisecond),
          "origin" => "localhost",
          "depth" => 1,
          "auth_events" => [],
          "prev_events" => [],
          "signatures" => %{},
          "hashes" => %{}
        },
        "10"
      )

    room_id
  end

  defp insert_message(room_id, sender) do
    event = %{
      "event_id" => "$#{System.unique_integer([:positive])}",
      "room_id" => room_id,
      "sender" => sender,
      "type" => "m.room.message",
      "content" => %{"body" => "hi"},
      "origin_server_ts" => System.os_time(:millisecond),
      "origin" => "localhost",
      "depth" => 2,
      "auth_events" => [],
      "prev_events" => [],
      "signatures" => %{},
      "hashes" => %{}
    }

    {:ok, persisted} = EventStore.insert_event(event, "10")
    EventStore.event_to_map(persisted)
  end

  test "returns immediately when events already exist since the given ordering" do
    user = new_user("alice")
    room_id = create_room_and_join(user)
    base = EventStore.room_max_stream_ordering(room_id)
    insert_message(room_id, user)

    assert {:ok, events_by_room} = Manager.wait_for_events(user, base, 5_000)
    assert Map.has_key?(events_by_room, room_id)
  end

  test "blocks, then returns once a matching event is broadcast" do
    user = new_user("alice")
    room_id = create_room_and_join(user)
    base = EventStore.room_max_stream_ordering(room_id)

    task = Task.async(fn -> Manager.wait_for_events(user, base, 5_000) end)
    # Give the task a moment to subscribe before we broadcast.
    Process.sleep(50)

    event_map = insert_message(room_id, user)
    Phoenix.PubSub.broadcast(@pubsub, "room:#{room_id}", {:new_event, room_id, event_map})

    assert {:ok, events_by_room} = Task.await(task, 5_000)
    assert Map.has_key?(events_by_room, room_id)
  end

  test "a to-device broadcast returns immediately even with no new room events" do
    user = new_user("alice")
    base = 0

    task = Task.async(fn -> Manager.wait_for_events(user, base, 5_000) end)
    Process.sleep(50)

    Phoenix.PubSub.broadcast(@pubsub, "user:#{user}", {:to_device, []})

    assert {:ok, _events} = Task.await(task, 5_000)
  end

  test "times out and returns an empty map when nothing arrives" do
    user = new_user("alice")
    assert Manager.wait_for_events(user, 0, 200) == {:ok, %{}}
  end

  test "wait_for_events/2 uses the default 30s timeout when omitted" do
    user = new_user("alice")
    room_id = create_room_and_join(user)
    base = EventStore.room_max_stream_ordering(room_id)
    insert_message(room_id, user)

    assert {:ok, events_by_room} = Manager.wait_for_events(user, base)
    assert Map.has_key?(events_by_room, room_id)
  end

  test "a device_list broadcast returns immediately even with no new room events" do
    user = new_user("alice")

    task = Task.async(fn -> Manager.wait_for_events(user, 0, 5_000) end)
    Process.sleep(50)

    Phoenix.PubSub.broadcast(@pubsub, "user:#{user}", {:device_list, user})

    assert {:ok, _events} = Task.await(task, 5_000)
  end

  test "an account_data broadcast returns immediately even with no new room events" do
    user = new_user("alice")

    task = Task.async(fn -> Manager.wait_for_events(user, 0, 5_000) end)
    Process.sleep(50)

    Phoenix.PubSub.broadcast(@pubsub, "user:#{user}", {:account_data, user})

    assert {:ok, _events} = Task.await(task, 5_000)
  end

  test "an ephemeral broadcast (typing/receipts) returns immediately even with no new room events" do
    user = new_user("alice")
    room_id = create_room_and_join(user)
    base = EventStore.room_max_stream_ordering(room_id)

    task = Task.async(fn -> Manager.wait_for_events(user, base, 5_000) end)
    Process.sleep(50)

    Phoenix.PubSub.broadcast(@pubsub, "room:#{room_id}", {:ephemeral, room_id})

    assert {:ok, _events} = Task.await(task, 5_000)
  end

  test "an explicit :sync_timeout message short-circuits the wait like a real timeout" do
    user = new_user("alice")
    pid = self()

    task =
      Task.async(fn ->
        send(pid, :ready_to_receive)
        Manager.wait_for_events(user, 0, 5_000)
      end)

    assert_receive :ready_to_receive, 1_000
    Process.sleep(50)
    send(task.pid, :sync_timeout)

    assert Task.await(task, 5_000) == {:ok, %{}}
  end

  test "multiple concurrent waiters for the same user are each notified independently" do
    user = new_user("alice")
    room_id = create_room_and_join(user)
    base = EventStore.room_max_stream_ordering(room_id)

    tasks = for _ <- 1..3, do: Task.async(fn -> Manager.wait_for_events(user, base, 5_000) end)
    Process.sleep(50)

    event_map = insert_message(room_id, user)
    Phoenix.PubSub.broadcast(@pubsub, "room:#{room_id}", {:new_event, room_id, event_map})

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.all?(results, fn {:ok, events} -> Map.has_key?(events, room_id) end)
  end
end
