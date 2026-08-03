defmodule AxonWeb.StateResolverTest do
  @moduledoc """
  Closes the Phase 2 gap where AxonRoom.StateResV2 (state resolution v2)
  was fully implemented but never invoked anywhere in the federation
  inbound path — RoomProcess only tracked a single linear current_state,
  so an inbound PDU whose prev_events forked away from the room's actual
  head (a genuine concurrent event, or catching up after missing some
  events) was auth-checked against the wrong state.

  This exercises AxonRoom.StateResolver, which detects that fork and
  builds a properly resolved state set (via StateResV2) for the auth
  check, and RoomProcess.apply_remote_event/2's use of it end-to-end.
  """

  use AxonWeb.ConnCase, async: false

  alias AxonCore.EventStore
  alias AxonRoom.{RoomProcess, StateResolver}

  defp register(username) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/register",
        Jason.encode!(%{
          "username" => username,
          "password" => "Test1234!",
          "kind" => "user",
          "auth" => %{"type" => "m.login.dummy"}
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    %{token: body["access_token"], user_id: body["user_id"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp jp(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token, opts) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", opts)
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  describe "needs_resolution?/2" do
    test "false when prev_events is empty or matches the current head" do
      refute StateResolver.needs_resolution?(%{"prev_events" => []}, "$head")
      refute StateResolver.needs_resolution?(%{"prev_events" => ["$head"]}, "$head")
    end

    test "true when prev_events diverges from the current head or has more than one entry" do
      assert StateResolver.needs_resolution?(%{"prev_events" => ["$other"]}, "$head")
      assert StateResolver.needs_resolution?(%{"prev_events" => ["$a", "$b"]}, "$head")
    end
  end

  test "resolves a conflicting key deterministically and passes unrelated state through" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})
    bob = register("bob_#{System.unique_integer([:positive])}")

    assert authed(bob.token)
           |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
           |> Map.get(:status) == 200

    {:ok, create_event} = EventStore.get_state_event(room_id, "m.room.create", "")
    {:ok, old_pl_event} = EventStore.get_state_event(room_id, "m.room.power_levels", "")
    {:ok, bob_member_event} = EventStore.get_state_event(room_id, "m.room.member", bob.user_id)

    {head0, depth0} = RoomProcess.get_position(room_id)

    # A legitimate power_levels change granting bob elevated power — this
    # becomes the room's real, accepted head.
    new_pl_content =
      Map.put(
        old_pl_event.content,
        "users",
        Map.put(old_pl_event.content["users"] || %{}, bob.user_id, 60)
      )

    assert {:ok, _pl_change_id} =
             RoomProcess.send_event(room_id, alice.user_id, "m.room.power_levels", new_pl_content,
               state_key: ""
             )

    {head1, _depth1} = RoomProcess.get_position(room_id)
    assert head1 != head0

    # A "concurrent" remote PDU built before its author had seen that change:
    # forks from head0, and its own auth_events reference the OLD power_levels.
    pdu_b = %{
      "event_id" => "$branchB_#{System.unique_integer([:positive])}:remote.example",
      "room_id" => room_id,
      "sender" => bob.user_id,
      "type" => "m.room.name",
      "state_key" => "",
      "content" => %{"name" => "Renamed by Bob"},
      "origin" => "remote.example",
      "origin_server_ts" => System.os_time(:millisecond),
      "prev_events" => [head0],
      "auth_events" => [create_event.event_id, old_pl_event.event_id, bob_member_event.event_id],
      "depth" => depth0 + 1,
      "signatures" => %{},
      "hashes" => %{}
    }

    assert StateResolver.needs_resolution?(pdu_b, head1)

    current_state = RoomProcess.get_state_map(room_id)
    {:ok, resolved} = StateResolver.resolve_for_auth_check(pdu_b, current_state, head1)

    pl_resolved = resolved[{"m.room.power_levels", ""}]

    # pdu_b's only prev_event (head0) predates the PL change and doesn't
    # match our current head (head1), so the walk reconstructs the real
    # historical state as of head0 from scratch rather than falling back to
    # (newer, unrelated) current_state — deterministically the OLD power
    # levels, not "either, we're not sure which."
    assert pl_resolved["event_id"] == old_pl_event.event_id

    assert resolved[{"m.room.create", ""}]["event_id"] == create_event.event_id

    {:ok, resolved_again} = StateResolver.resolve_for_auth_check(pdu_b, current_state, head1)
    assert resolved_again[{"m.room.power_levels", ""}]["event_id"] == pl_resolved["event_id"]
  end

  test "apply_remote_event doesn't crash on a forking PDU and yields a well-formed result" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    {:ok, create_event} = EventStore.get_state_event(room_id, "m.room.create", "")
    {:ok, pl_event} = EventStore.get_state_event(room_id, "m.room.power_levels", "")

    {:ok, alice_member_event} =
      EventStore.get_state_event(room_id, "m.room.member", alice.user_id)

    {head0, depth0} = RoomProcess.get_position(room_id)

    assert {:ok, _} =
             RoomProcess.send_event(
               room_id,
               alice.user_id,
               "m.room.topic",
               %{"topic" => "unrelated change"},
               state_key: ""
             )

    forking_pdu = %{
      "event_id" => "$branchC_#{System.unique_integer([:positive])}:remote.example",
      "room_id" => room_id,
      "sender" => alice.user_id,
      "type" => "m.room.name",
      "state_key" => "",
      "content" => %{"name" => "Concurrent rename"},
      "origin" => "remote.example",
      "origin_server_ts" => System.os_time(:millisecond),
      "prev_events" => [head0],
      "auth_events" => [create_event.event_id, pl_event.event_id, alice_member_event.event_id],
      "depth" => depth0 + 1,
      "signatures" => %{},
      "hashes" => %{}
    }

    assert {:ok, event_id} = RoomProcess.apply_remote_event(room_id, forking_pdu)
    assert event_id == forking_pdu["event_id"]
  end

  test "current_state is rebased onto resolved state after a merge PDU, not just used to gate the auth check" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    {:ok, room} = EventStore.get_room(room_id)
    {:ok, create_event} = EventStore.get_state_event(room_id, "m.room.create", "")
    {:ok, pl_event} = EventStore.get_state_event(room_id, "m.room.power_levels", "")

    {:ok, alice_member_event} =
      EventStore.get_state_event(room_id, "m.room.member", alice.user_id)

    {head0, depth0} = RoomProcess.get_position(room_id)

    # A foreign event we already know about (e.g. backfilled) but that our
    # own RoomProcess head never advanced through — inserted directly,
    # bypassing RoomProcess, to simulate exactly that.
    name_a = %{
      "event_id" => "$name_a_rebase_#{System.unique_integer([:positive])}:remote.example",
      "room_id" => room_id,
      "sender" => alice.user_id,
      "type" => "m.room.name",
      "state_key" => "",
      "content" => %{"name" => "Set concurrently"},
      "origin" => "remote.example",
      "origin_server_ts" => System.os_time(:millisecond),
      "prev_events" => [head0],
      "auth_events" => [create_event.event_id, pl_event.event_id, alice_member_event.event_id],
      "depth" => depth0 + 1,
      "signatures" => %{},
      "hashes" => %{}
    }

    {:ok, _} = EventStore.insert_event(name_a, room.version)

    # The event we actually hand to RoomProcess is a genuine 2-way merge
    # (prev_events cites both head0 and name_a) but is itself a plain
    # message — it doesn't touch m.room.name at all. Under the old
    # blind-overlay behavior, applying a message event never changes
    # current_state, so name_a's contribution (only reachable via
    # resolution, never applied to our own head directly) would be lost
    # entirely. Under the fix, current_state gets rebased onto the
    # resolved state (which correctly adopts name_a) before the message's
    # own (no-op) overlay.
    merge_pdu = %{
      "event_id" => "$merge_rebase_#{System.unique_integer([:positive])}:remote.example",
      "room_id" => room_id,
      "sender" => alice.user_id,
      "type" => "m.room.message",
      "content" => %{"msgtype" => "m.text", "body" => "merging branches"},
      "origin" => "remote.example",
      "origin_server_ts" => System.os_time(:millisecond),
      "prev_events" => [head0, name_a["event_id"]],
      "auth_events" => [create_event.event_id, pl_event.event_id, alice_member_event.event_id],
      "depth" => depth0 + 1,
      "signatures" => %{},
      "hashes" => %{}
    }

    assert {:ok, _} = RoomProcess.apply_remote_event(room_id, merge_pdu)

    current_state = RoomProcess.get_state_map(room_id)
    assert current_state[{"m.room.name", ""}]["content"]["name"] == "Set concurrently"

    # Not just the in-memory map — the room's actually-served state too.
    conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.name")
    assert conn.status == 200
    assert decode(conn)["name"] == "Set concurrently"
  end
end
