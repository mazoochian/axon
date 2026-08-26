defmodule AxonWeb.SyncArchivedRoomsTest do
  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers
  alias AxonCore.EventStore

  defp sync(token, opts \\ []) do
    query =
      opts
      |> Enum.map(fn {key, value} -> {key, to_string(value)} end)
      |> URI.encode_query()

    path = "/_matrix/client/v3/sync" <> if(query == "", do: "", else: "?" <> query)
    conn = authed(token) |> get(path)
    assert conn.status == 200
    decode(conn)
  end

  defp leave(token, room_id) do
    conn = authed(token) |> jp("/_matrix/client/v3/rooms/#{room_id}/leave", %{})
    assert conn.status == 200
  end

  defp forget(token, room_id) do
    conn = authed(token) |> jp("/_matrix/client/v3/rooms/#{room_id}/forget", %{})
    assert conn.status == 200
  end

  defp include_leave_filter(value) do
    Jason.encode!(%{"room" => %{"include_leave" => value}})
  end

  defp send_state(token, room_id, type, content) do
    conn = authed(token) |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/#{type}/", content)
    assert conn.status == 200
    decode(conn)["event_id"]
  end

  test "archived room timelines stop at the latest leave and respect sync boundaries" do
    alice = register("archive_alice_#{System.unique_integer([:positive])}")
    bob = register("archive_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    assert (authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})).status == 200
    before_since = sync(bob.token)["next_batch"]

    before_id =
      send_event(alice.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "before leave"
      })

    leave(bob.token, room_id)

    after_id =
      send_event(alice.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "after leave"
      })

    for response <- [
          sync(bob.token, filter: include_leave_filter(true)),
          sync(bob.token, since: before_since)
        ] do
      room = get_in(response, ["rooms", "leave", room_id])
      assert room, "archived room missing from sync"

      timeline = room["timeline"]
      ids = Enum.map(timeline["events"], & &1["event_id"])

      assert before_id in ids

      assert Enum.any?(timeline["events"], fn event ->
               event["type"] == "m.room.member" and
                 event["state_key"] == bob.user_id and
                 event["content"]["membership"] == "leave"
             end)

      refute after_id in ids
      refute Enum.any?(timeline["events"], &(&1["content"]["body"] == "after leave"))
      assert timeline["limited"] == false
      assert is_binary(timeline["prev_batch"])
    end

    after_leave_since = sync(bob.token)["next_batch"]
    response = sync(bob.token, since: after_leave_since)
    refute get_in(response, ["rooms", "leave", room_id])
  end

  test "initial sync omits historical leave rooms unless include_leave is true" do
    alice = register("archive_include_alice_#{System.unique_integer([:positive])}")
    bob = register("archive_include_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    assert (authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})).status == 200
    leave(bob.token, room_id)

    refute get_in(sync(bob.token), ["rooms", "leave", room_id])

    refute get_in(sync(bob.token, filter: include_leave_filter(false)), [
             "rooms",
             "leave",
             room_id
           ])

    assert get_in(sync(bob.token, filter: include_leave_filter(true)), [
             "rooms",
             "leave",
             room_id
           ])
  end

  test "incremental sync includes a newly left room regardless of include_leave" do
    alice = register("archive_incremental_alice_#{System.unique_integer([:positive])}")
    bob = register("archive_incremental_bob_#{System.unique_integer([:positive])}")

    for filter <- [nil, include_leave_filter(false)] do
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      assert (authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})).status == 200
      since = sync(bob.token)["next_batch"]
      leave(bob.token, room_id)

      opts = [since: since] ++ if(filter, do: [filter: filter], else: [])
      assert get_in(sync(bob.token, opts), ["rooms", "leave", room_id])
    end
  end

  test "forgotten rooms are excluded from incremental sync even from a pre-leave token" do
    alice = register("archive_forget_alice_#{System.unique_integer([:positive])}")
    bob = register("archive_forget_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    assert (authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})).status == 200
    since = sync(bob.token)["next_batch"]
    leave(bob.token, room_id)
    forget(bob.token, room_id)

    refute get_in(sync(bob.token, since: since), ["rooms", "leave", room_id])

    refute get_in(sync(bob.token, since: since, filter: include_leave_filter(true)), [
             "rooms",
             "leave",
             room_id
           ])
  end

  test "Complement TestArchivedRoomsHistory filtering and zero-limit state are leave-bounded" do
    alice = register("archive_filter_alice_#{System.unique_integer([:positive])}")
    bob = register("archive_filter_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})
    assert (authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})).status == 200

    filter = %{
      "room" => %{
        "timeline" => %{"types" => ["m.room.message", "a.madeup.test.state"]},
        "state" => %{"types" => ["a.madeup.test.state"]},
        "include_leave" => true
      }
    }

    before_since = sync(bob.token, filter: Jason.encode!(filter))["next_batch"]

    send_event(alice.token, room_id, "m.room.message", %{
      "msgtype" => "m.text",
      "body" => "before"
    })

    send_state(alice.token, room_id, "a.madeup.test.state", %{"my_key" => "before"})
    leave(bob.token, room_id)

    send_event(alice.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "after"})

    send_state(alice.token, room_id, "a.madeup.test.state", %{"my_key" => "after"})

    for response <- [
          sync(bob.token, filter: Jason.encode!(filter)),
          sync(bob.token, since: before_since, filter: Jason.encode!(filter))
        ] do
      room = get_in(response, ["rooms", "leave", room_id])

      assert Enum.map(room["timeline"]["events"], & &1["type"]) == [
               "m.room.message",
               "a.madeup.test.state"
             ]

      assert Enum.map(room["timeline"]["events"], & &1["content"]) == [
               %{"msgtype" => "m.text", "body" => "before"},
               %{"my_key" => "before"}
             ]

      assert room["state"]["events"] == []
    end

    zero_filter = %{"room" => %{"timeline" => %{"limit" => 0}, "include_leave" => true}}

    room =
      get_in(sync(bob.token, filter: Jason.encode!(zero_filter)), ["rooms", "leave", room_id])

    assert room["timeline"]["events"] == []
    assert room["timeline"]["limited"] == true

    leave_event =
      room["state"]["events"]
      |> Enum.find(fn event ->
        event["type"] == "m.room.member" and event["state_key"] == bob.user_id and
          event["content"]["membership"] == "leave"
      end)

    {:ok, persisted_leave} = EventStore.get_event(leave_event["event_id"])

    assert room["timeline"]["prev_batch"] ==
             Integer.to_string(persisted_leave.stream_ordering + 1)

    assert Enum.any?(room["state"]["events"], fn event ->
             event["type"] == "a.madeup.test.state" and event["content"]["my_key"] == "before"
           end)

    assert Enum.any?(room["state"]["events"], fn event ->
             event["type"] == "m.room.member" and event["state_key"] == bob.user_id and
               event["content"]["membership"] == "leave"
           end)

    one_filter = %{"room" => %{"timeline" => %{"limit" => 1}, "include_leave" => true}}

    one_room =
      get_in(sync(bob.token, filter: Jason.encode!(one_filter)), ["rooms", "leave", room_id])

    assert length(one_room["timeline"]["events"]) == 1
    assert one_room["timeline"]["limited"] == true
    [one_event] = one_room["timeline"]["events"]
    {:ok, persisted_one} = EventStore.get_event(one_event["event_id"])
    assert one_room["timeline"]["prev_batch"] == Integer.to_string(persisted_one.stream_ordering)
  end

  test "archived timeline filters are applied before a restrictive limit" do
    alice = register("archive_limit_alice_#{System.unique_integer([:positive])}")
    bob = register("archive_limit_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})
    assert (authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})).status == 200

    wanted_id =
      send_event(alice.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "wanted"
      })

    send_state(alice.token, room_id, "a.noise.one", %{"value" => 1})
    send_state(alice.token, room_id, "a.noise.two", %{"value" => 2})

    newest_wanted_id =
      send_event(alice.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "newest wanted"
      })

    leave(bob.token, room_id)

    filter = %{
      "room" => %{
        "include_leave" => true,
        "timeline" => %{"limit" => 1, "types" => ["m.room.message"]}
      }
    }

    room =
      get_in(sync(bob.token, filter: Jason.encode!(filter)), ["rooms", "leave", room_id])

    assert Enum.map(room["timeline"]["events"], & &1["event_id"]) == [newest_wanted_id]
    assert room["timeline"]["limited"] == true
    {:ok, newest_wanted} = EventStore.get_event(newest_wanted_id)
    assert room["timeline"]["prev_batch"] == Integer.to_string(newest_wanted.stream_ordering)
    refute wanted_id == newest_wanted_id
  end

  test "a newly banned room is emitted as leave and remains bounded at the ban" do
    alice = register("archive_ban_alice_#{System.unique_integer([:positive])}")
    bob = register("archive_ban_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})
    assert (authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})).status == 200
    since = sync(bob.token)["next_batch"]

    assert (authed(alice.token)
            |> jp("/_matrix/client/v3/rooms/#{room_id}/ban", %{"user_id" => bob.user_id})).status ==
             200

    after_ban =
      send_event(alice.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "after ban"
      })

    room = get_in(sync(bob.token, since: since), ["rooms", "leave", room_id])
    assert Enum.any?(room["timeline"]["events"], &(&1["content"]["membership"] == "ban"))
    refute Enum.any?(room["timeline"]["events"], &(&1["event_id"] == after_ban))
  end

  test "a rejoin followed by another leave uses the latest leave event as the cutoff" do
    alice = register("archive_cycle_alice_#{System.unique_integer([:positive])}")
    bob = register("archive_cycle_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    assert (authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})).status == 200
    leave(bob.token, room_id)

    first_absence_id =
      send_event(alice.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "absent"
      })

    assert (authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})).status == 200
    refute get_in(sync(bob.token), ["rooms", "leave", room_id])

    second_cycle_id =
      send_event(alice.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "second cycle"
      })

    leave(bob.token, room_id)

    after_latest_leave_id =
      send_event(alice.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "too late"
      })

    events =
      get_in(sync(bob.token, filter: include_leave_filter(true)), [
        "rooms",
        "leave",
        room_id,
        "timeline",
        "events"
      ])

    ids = Enum.map(events, & &1["event_id"])

    assert first_absence_id in ids
    assert second_cycle_id in ids
    refute after_latest_leave_id in ids

    leave_events =
      Enum.filter(events, fn event ->
        event["type"] == "m.room.member" and event["state_key"] == bob.user_id and
          event["content"]["membership"] == "leave"
      end)

    assert length(leave_events) == 2
    assert List.last(leave_events)["event_id"] == List.last(ids)
  end
end
