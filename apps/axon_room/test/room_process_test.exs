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

    {:ok, %{user_id: user_id}} =
      UserStore.register(localpart, "Test1234!", server_name: "localhost")

    user_id
  end

  describe "state snapshotting (regression: NUL-byte separator broke every save)" do
    test "crossing the snapshot interval actually persists a loadable snapshot" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")

      # CreateRoom already sent ~6 state events; send enough more messages to
      # cross @snapshot_interval (100) and trigger the fire-and-forget save.
      for _ <- 1..100 do
        {:ok, _} =
          RoomProcess.send_event(room_id, creator, "m.room.message", %{"body" => "filler"})
      end

      # save_snapshot runs in a Task.Supervisor child; give it a moment.
      snapshot =
        Enum.reduce_while(1..50, nil, fn _, _ ->
          case AxonCore.EventStore.latest_snapshot(room_id) do
            nil ->
              Process.sleep(20)
              {:cont, nil}

            snap ->
              {:halt, snap}
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

    test "restarting the process after a snapshot exists loads from it, not a full replay" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")

      for _ <- 1..100 do
        {:ok, _} =
          RoomProcess.send_event(room_id, creator, "m.room.message", %{"body" => "filler"})
      end

      Enum.reduce_while(1..50, nil, fn _, _ ->
        case AxonCore.EventStore.latest_snapshot(room_id) do
          nil ->
            Process.sleep(20)
            {:cont, nil}

          snap ->
            {:halt, snap}
        end
      end)

      {:ok, event_id} =
        RoomProcess.send_event(room_id, creator, "m.room.message", %{"body" => "after snapshot"})

      :ok = RoomProcess.stop_if_running(room_id)

      Enum.reduce_while(1..50, nil, fn _, _ ->
        case RoomProcess.get_or_start(room_id) do
          {:ok, _pid} ->
            {:halt, :ok}

          _ ->
            Process.sleep(10)
            {:cont, nil}
        end
      end)

      {last_event_id, _depth} = RoomProcess.get_position(room_id)
      assert last_event_id == event_id
      assert RoomProcess.get_state_event(room_id, "m.room.create", "")
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

      {:ok, room_id} =
        CreateRoom.execute(creator, server_name: "localhost", preset: "public_chat")

      {:ok, _} =
        RoomProcess.send_event(room_id, bob, "m.room.member", %{"membership" => "join"},
          state_key: bob
        )

      assert RoomProcess.send_event(room_id, bob, "m.room.name", %{"name" => "Hijacked"},
               state_key: ""
             ) ==
               {:error, :insufficient_power}

      refute RoomProcess.get_state_event(room_id, "m.room.name", "")
    end
  end

  describe "apply_remote_event/2 — auth rejection" do
    test "a PDU that fails auth is rejected, not applied, but IS stored as rejected" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")
      {last_event_id, depth} = RoomProcess.get_position(room_id)

      bogus_pdu = %{
        "event_id" => "$bogus_#{System.unique_integer([:positive])}:remote.example",
        "room_id" => room_id,
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

      # Per spec, a rejected event is still *stored*, just never applied —
      # not "as if it was never sent".
      assert {:ok, stored} = AxonCore.EventStore.get_event(bogus_pdu["event_id"])
      assert stored.rejected == true

      # And excluded from /sync's event stream.
      events = AxonCore.EventStore.get_events_since(room_id, 0, 1000)
      refute Enum.any?(events, &(&1.event_id == bogus_pdu["event_id"]))
    end
  end

  describe "apply_remote_event/2 — unknown ancestor (unresolvable prev_events)" do
    test "a PDU whose only prev_event is unfetchable is refused, stored rejected, and never applied" do
      creator = new_user("alice")

      {:ok, room_id} =
        CreateRoom.execute(creator, server_name: "localhost", preset: "public_chat")

      remote_user = "@ghost:federated.example"

      # Join remote_user first so a plain AuthRules.check against *current*
      # state would otherwise happily accept the next event from them —
      # isolating this test to the ancestor-resolution refusal, not an
      # unrelated auth failure.
      {last_event_id, depth} = RoomProcess.get_position(room_id)

      join_pdu = %{
        "event_id" => "$ghostjoin_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.member",
        "state_key" => remote_user,
        "sender" => remote_user,
        "content" => %{"membership" => "join"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      {:ok, _} = RoomProcess.apply_remote_event(room_id, join_pdu)
      {head_before, depth_before} = RoomProcess.get_position(room_id)

      missing_ancestor_id = "$never-sent-this-#{System.unique_integer([:positive])}"

      orphan_pdu = %{
        "event_id" => "$orphan_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.custom.event",
        "sender" => remote_user,
        "content" => %{"whatever" => "goes"},
        "depth" => depth_before + 1,
        "prev_events" => [missing_ancestor_id],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      assert RoomProcess.apply_remote_event(room_id, orphan_pdu) == {:error, :unknown_ancestor}

      # Not applied: room position unchanged, event absent from current state.
      assert RoomProcess.get_position(room_id) == {head_before, depth_before}

      # But stored, marked rejected, per spec.
      assert {:ok, stored} = AxonCore.EventStore.get_event(orphan_pdu["event_id"])
      assert stored.rejected == true

      events = AxonCore.EventStore.get_events_since(room_id, 0, 1000)
      refute Enum.any?(events, &(&1.event_id == orphan_pdu["event_id"]))
    end
  end

  describe "apply_remote_event/2 — unreject on a later-arriving ancestor" do
    test "an event rejected for an unresolvable prev_event is unrejected, with a fresh " <>
           "stream_ordering, once that ancestor arrives (Complement: TestUnrejectRejectedEvents)" do
      creator = new_user("alice")

      {:ok, room_id} =
        CreateRoom.execute(creator, server_name: "localhost", preset: "public_chat")

      remote_user = "@bob:federated.example"

      {last_event_id, depth} = RoomProcess.get_position(room_id)

      join_pdu = %{
        "event_id" => "$bobjoin_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.member",
        "state_key" => remote_user,
        "sender" => remote_user,
        "content" => %{"membership" => "join"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      {:ok, join_event_id} = RoomProcess.apply_remote_event(room_id, join_pdu)

      event_a_id = "$event_a_#{System.unique_integer([:positive])}"

      event_a_pdu = %{
        "event_id" => event_a_id,
        "room_id" => room_id,
        "type" => "m.event.a",
        "sender" => remote_user,
        "content" => %{"event" => "A"},
        "depth" => depth + 2,
        "prev_events" => [join_event_id],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      event_b_pdu = %{
        "event_id" => "$event_b_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.event.b",
        "sender" => remote_user,
        "content" => %{"event" => "B"},
        "depth" => depth + 3,
        "prev_events" => [event_a_id],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      # Send B first: A is unknown, so this must be refused and stored rejected.
      assert RoomProcess.apply_remote_event(room_id, event_b_pdu) == {:error, :unknown_ancestor}
      assert {:ok, stored_b} = AxonCore.EventStore.get_event(event_b_pdu["event_id"])
      assert stored_b.rejected == true
      rejected_ordering = stored_b.stream_ordering

      # Now send A — it lands cleanly (its own prev_event is our current head).
      assert {:ok, ^event_a_id} = RoomProcess.apply_remote_event(room_id, event_a_pdu)
      assert {:ok, stored_a} = AxonCore.EventStore.get_event(event_a_id)

      # A "since" token captured right after A arrives — B must appear as a
      # genuinely *new* event after this point, not be missed because it
      # already sorted before it back when it was (wrongly) inserted rejected.
      since_ordering = stored_a.stream_ordering

      # Resend B — A now exists, so this unrejects it.
      assert RoomProcess.apply_remote_event(room_id, event_b_pdu) ==
               {:ok, event_b_pdu["event_id"]}

      assert {:ok, unrejected_b} = AxonCore.EventStore.get_event(event_b_pdu["event_id"])
      assert unrejected_b.rejected == false
      assert unrejected_b.stream_ordering > rejected_ordering
      assert unrejected_b.stream_ordering > since_ordering

      # And it shows up as a new event after the since token, per the
      # Complement test's `MustSyncUntil(Since: since, ...eventB...)`.
      events_after_since = AxonCore.EventStore.get_events_since(room_id, since_ordering, 1000)
      assert Enum.any?(events_after_since, &(&1.event_id == event_b_pdu["event_id"]))
    end
  end

  describe "apply_remote_event/2 — transitive auth rejection" do
    test "a PDU whose auth_events reference an already-rejected event is itself rejected" do
      creator = new_user("alice")

      {:ok, room_id} =
        CreateRoom.execute(creator, server_name: "localhost", preset: "public_chat")

      {last_event_id, depth} = RoomProcess.get_position(room_id)

      # First, get a genuinely rejected event on the books (an unjoined
      # sender's event fails AuthRules.check outright).
      rejected_id = "$rejected_ancestor_#{System.unique_integer([:positive])}"

      rejected_pdu = %{
        "event_id" => rejected_id,
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => "@intruder:remote.example",
        "content" => %{"body" => "should not land"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [],
        "origin" => "remote.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      assert RoomProcess.apply_remote_event(room_id, rejected_pdu) == {:error, :not_joined}
      assert {:ok, stored} = AxonCore.EventStore.get_event(rejected_id)
      assert stored.rejected == true

      # Now send a perfectly legitimate event from the (already-joined)
      # creator, except it lists the rejected event as one of its
      # auth_events. Per spec this must itself be rejected, regardless of
      # what AuthRules.check would otherwise say.
      dependent_pdu = %{
        "event_id" => "$dependent_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => creator,
        "content" => %{"body" => "hi"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [rejected_id],
        "origin" => "localhost",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      assert RoomProcess.apply_remote_event(room_id, dependent_pdu) ==
               {:error, :auth_event_rejected}

      assert RoomProcess.get_position(room_id) == {last_event_id, depth}

      assert {:ok, dependent_stored} = AxonCore.EventStore.get_event(dependent_pdu["event_id"])
      assert dependent_stored.rejected == true
    end

    test "a PDU whose auth_events reference an event we have no record of at all is " <>
           "rejected too, not just one we know is rejected " <>
           "(Complement: TestInboundFederationRejectsEventsWithRejectedAuthEvents)" do
      creator = new_user("alice")

      {:ok, room_id} =
        CreateRoom.execute(creator, server_name: "localhost", preset: "public_chat")

      {last_event_id, depth} = RoomProcess.get_position(room_id)

      # An id this server was never sent and never fetched — not stored as
      # accepted, not stored as rejected, simply absent. Unlike the sibling
      # "transitive auth rejection" test above (a *known*-rejected ancestor),
      # this is the "outlier we don't have at all" case.
      never_seen_id = "$never_seen_outlier_#{System.unique_integer([:positive])}"

      dependent_pdu = %{
        "event_id" => "$dependent_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => creator,
        "content" => %{"body" => "hi"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [never_seen_id],
        "origin" => "localhost",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      assert RoomProcess.apply_remote_event(room_id, dependent_pdu) ==
               {:error, :unknown_auth_event}

      assert RoomProcess.get_position(room_id) == {last_event_id, depth}

      assert {:ok, dependent_stored} = AxonCore.EventStore.get_event(dependent_pdu["event_id"])
      assert dependent_stored.rejected == true

      # The never-seen id itself must stay exactly that — absent — not get
      # invented as a side effect of the check.
      assert AxonCore.EventStore.get_event(never_seen_id) == {:error, :not_found}
    end
  end

  describe "apply_remote_event/2 — success paths" do
    test "a valid PDU from an already-joined remote user is applied and broadcast" do
      creator = new_user("alice")

      {:ok, room_id} =
        CreateRoom.execute(creator, server_name: "localhost", preset: "public_chat")

      remote_user = "@remote:federated.example"
      {last_event_id, depth} = RoomProcess.get_position(room_id)

      join_pdu = %{
        "event_id" => "$remotejoin_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.member",
        "state_key" => remote_user,
        "sender" => remote_user,
        "content" => %{"membership" => "join"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      assert {:ok, join_event_id} = RoomProcess.apply_remote_event(room_id, join_pdu)
      assert join_event_id == join_pdu["event_id"]

      assert RoomProcess.get_state_event(room_id, "m.room.member", remote_user)["content"][
               "membership"
             ] == "join"

      Phoenix.PubSub.subscribe(Axon.PubSub, "room:#{room_id}")
      {last_event_id2, depth2} = RoomProcess.get_position(room_id)

      message_pdu = %{
        "event_id" => "$remotemsg_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => remote_user,
        "content" => %{"body" => "hello from federation"},
        "depth" => depth2 + 1,
        "prev_events" => [last_event_id2],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      assert {:ok, msg_event_id} = RoomProcess.apply_remote_event(room_id, message_pdu)
      assert msg_event_id == message_pdu["event_id"]

      assert_receive {:new_event, ^room_id, event_map}
      assert event_map["event_id"] == msg_event_id
    end

    test "a PDU whose prev_events fork away from our head triggers state resolution instead of crashing" do
      creator = new_user("alice")

      {:ok, room_id} =
        CreateRoom.execute(creator, server_name: "localhost", preset: "public_chat")

      remote_user = "@remote2:federated.example"
      {last_event_id, depth} = RoomProcess.get_position(room_id)

      join_pdu = %{
        "event_id" => "$forkjoin_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.member",
        "state_key" => remote_user,
        "sender" => remote_user,
        "content" => %{"membership" => "join"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      {:ok, _} = RoomProcess.apply_remote_event(room_id, join_pdu)

      # A "concurrent" event forking off the room's head from *before* the
      # join (two prev_events → needs_resolution?/2 returns true).
      forked_pdu = %{
        "event_id" => "$forked_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => remote_user,
        "content" => %{"body" => "concurrent"},
        "depth" => depth + 2,
        "prev_events" => [last_event_id, join_pdu["event_id"]],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      assert {:ok, _} = RoomProcess.apply_remote_event(room_id, forked_pdu)
    end
  end

  describe "stop_if_running/1" do
    test "terminates a resident process, which restarts fresh on next access" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")

      {:ok, pid_before} = RoomProcess.get_or_start(room_id)
      assert Process.alive?(pid_before)

      :ok = RoomProcess.stop_if_running(room_id)

      # Give the supervisor a beat to actually terminate the child.
      Enum.reduce_while(1..50, nil, fn _, _ ->
        if Process.alive?(pid_before),
          do:
            (
              Process.sleep(10)
              {:cont, nil}
            ),
          else: {:halt, :ok}
      end)

      refute Process.alive?(pid_before)

      {:ok, pid_after} = RoomProcess.get_or_start(room_id)
      refute pid_after == pid_before
      assert RoomProcess.get_state_event(room_id, "m.room.create", "")
    end

    test "is a no-op for a room with no resident process" do
      assert RoomProcess.stop_if_running(
               "!never_started_#{System.unique_integer([:positive])}:localhost"
             ) ==
               :ok
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
      assert {:error, _} =
               RoomProcess.get_or_start(
                 "!nonexistent_#{System.unique_integer([:positive])}:localhost"
               )
    end
  end

  describe "state getters" do
    test "get_position/get_room_ctx/get_state_map reflect a sequence of sends" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost", name: "Room")

      {:ok, event_id} =
        RoomProcess.send_event(room_id, creator, "m.room.message", %{"body" => "hello"})

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
