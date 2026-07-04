defmodule AxonCore.EventStoreTest do
  @moduledoc """
  Direct tests for `AxonCore.EventStore` against real Postgres (via
  `AxonCore.DataCase`) — event persistence, derived-state materialization,
  pagination, relation bundling, search, and snapshots.
  """

  use AxonCore.DataCase, async: false

  alias AxonCore.EventStore

  @room "!room:localhost"
  @creator "@creator:localhost"

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "event_id" => "$#{System.unique_integer([:positive])}",
        "room_id" => @room,
        "sender" => @creator,
        "type" => "m.room.message",
        "content" => %{"msgtype" => "m.text", "body" => "hi"},
        "origin_server_ts" => System.os_time(:millisecond),
        "origin" => "localhost",
        "depth" => 1,
        "auth_events" => [],
        "prev_events" => [],
        "signatures" => %{},
        "hashes" => %{}
      },
      overrides
    )
  end

  defp insert_user(user_id) do
    localpart = user_id |> String.trim_leading("@") |> String.split(":") |> hd()
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "users",
      [%{user_id: user_id, localpart: localpart, is_guest: false, deactivated: false, admin: false, inserted_at: now, updated_at: now}],
      on_conflict: :nothing
    )
  end

  setup do
    insert_user(@creator)
    {:ok, _room} = EventStore.insert_room(@room, @creator, "10", false)
    :ok
  end

  describe "insert_room / get_room" do
    test "round-trips version/creator/visibility" do
      assert {:ok, room} = EventStore.get_room(@room)
      assert room.creator == @creator
      assert room.version == "10"
      assert room.is_public == false
    end

    test "an unknown room_id is not_found" do
      assert EventStore.get_room("!nope:localhost") == {:error, :not_found}
    end
  end

  describe "insert_event" do
    test "persists a message event and it's retrievable by event_id" do
      ev = event()
      assert {:ok, persisted} = EventStore.insert_event(ev, "10")
      assert persisted.event_id == ev["event_id"]
      assert {:ok, fetched} = EventStore.get_event(ev["event_id"])
      assert fetched.event_id == ev["event_id"]
    end

    test "is idempotent: inserting the same event_id twice doesn't error or duplicate" do
      ev = event()
      assert {:ok, _} = EventStore.insert_event(ev, "10")
      assert {:ok, _} = EventStore.insert_event(ev, "10")

      count =
        EventStore.get_events_since(@room, 0, 1000) |> Enum.count(&(&1.event_id == ev["event_id"]))

      assert count == 1
    end

    test "a state event materializes into current_room_state" do
      ev = event(%{"type" => "m.room.name", "state_key" => "", "content" => %{"name" => "Hello"}})
      assert {:ok, _} = EventStore.insert_event(ev, "10")

      assert {:ok, state_event} = EventStore.get_state_event(@room, "m.room.name", "")
      assert state_event.content["name"] == "Hello"
    end

    test "a later state event for the same key replaces the earlier one in current_room_state" do
      ev1 = event(%{"type" => "m.room.topic", "state_key" => "", "content" => %{"topic" => "v1"}, "depth" => 1})
      ev2 = event(%{"type" => "m.room.topic", "state_key" => "", "content" => %{"topic" => "v2"}, "depth" => 2})

      {:ok, _} = EventStore.insert_event(ev1, "10")
      {:ok, _} = EventStore.insert_event(ev2, "10")

      assert {:ok, state_event} = EventStore.get_state_event(@room, "m.room.topic", "")
      assert state_event.content["topic"] == "v2"
    end

    test "a membership event derives a room_memberships row" do
      ev = event(%{"type" => "m.room.member", "state_key" => @creator, "sender" => @creator, "content" => %{"membership" => "join"}})
      assert {:ok, _} = EventStore.insert_event(ev, "10")
      assert EventStore.get_membership(@room, @creator) == {:ok, "join"}
    end

    test "a non-state event does not appear in current_room_state" do
      ev = event()
      {:ok, _} = EventStore.insert_event(ev, "10")
      state = EventStore.get_current_state_map(@room)
      refute Map.has_key?(state, {"m.room.message", nil})
    end
  end

  describe "event_to_map/1" do
    # Regression: "origin" was silently dropped when rebuilding the wire map
    # from a persisted %Event{}, which broke signature verification on every
    # federation-fanned-out event (origin is signable content).
    test "round-trips \"origin\"" do
      ev = event(%{"origin" => "some-remote.example"})
      {:ok, persisted} = EventStore.insert_event(ev, "10")

      wire_map = EventStore.event_to_map(persisted)
      assert wire_map["origin"] == "some-remote.example"
    end
  end

  describe "get_events_since / get_messages" do
    setup do
      base = EventStore.room_max_stream_ordering(@room)
      e1 = event(%{"content" => %{"body" => "one"}})
      e2 = event(%{"content" => %{"body" => "two"}})
      e3 = event(%{"content" => %{"body" => "three"}})
      {:ok, p1} = EventStore.insert_event(e1, "10")
      {:ok, p2} = EventStore.insert_event(e2, "10")
      {:ok, p3} = EventStore.insert_event(e3, "10")
      %{base: base, p1: p1, p2: p2, p3: p3}
    end

    test "get_events_since returns events in ascending order after the given ordering", %{base: base, p1: p1, p2: p2, p3: p3} do
      events = EventStore.get_events_since(@room, base, 10)
      assert Enum.map(events, & &1.event_id) == [p1.event_id, p2.event_id, p3.event_id]
    end

    test "get_events_since respects the limit", %{base: base} do
      assert length(EventStore.get_events_since(@room, base, 2)) == 2
    end

    test "get_messages backwards (dir=b) returns newest-first before the given ordering", %{p3: p3} do
      [first | _] = EventStore.get_messages(@room, p3.stream_ordering + 1, "b", 10)
      assert first.event_id == p3.event_id
    end

    test "get_messages forwards (dir=f) returns oldest-first after the given ordering", %{base: base, p1: p1} do
      [first | _] = EventStore.get_messages(@room, base, "f", 10)
      assert first.event_id == p1.event_id
    end
  end

  describe "search_messages" do
    test "finds a message by body text and reports a total count" do
      {:ok, _} = EventStore.insert_event(event(%{"content" => %{"msgtype" => "m.text", "body" => "the quick brown fox"}}), "10")
      {:ok, _} = EventStore.insert_event(event(%{"content" => %{"msgtype" => "m.text", "body" => "unrelated message"}}), "10")

      {hits, count} = EventStore.search_messages([@room], "quick fox", "rank", 10)
      assert count == 1
      assert [{event_id, _rank}] = hits
      assert is_binary(event_id)
    end

    test "returns no hits for a non-matching term" do
      {:ok, _} = EventStore.insert_event(event(%{"content" => %{"msgtype" => "m.text", "body" => "hello world"}}), "10")
      assert EventStore.search_messages([@room], "zzz_no_match_zzz", "rank", 10) == {[], 0}
    end

    test "an empty room list short-circuits to no hits" do
      assert EventStore.search_messages([], "anything", "rank", 10) == {[], 0}
    end
  end

  describe "relations bundling" do
    test "bundles m.annotation (reaction) counts by key" do
      target = event(%{"content" => %{"body" => "react to me"}})
      {:ok, _} = EventStore.insert_event(target, "10")

      for _ <- 1..2 do
        {:ok, _} =
          EventStore.insert_event(
            event(%{
              "type" => "m.reaction",
              "content" => %{"m.relates_to" => %{"rel_type" => "m.annotation", "event_id" => target["event_id"], "key" => "👍"}}
            }),
            "10"
          )
      end

      [bundled] = EventStore.bundle_relations(@room, [target])
      chunk = get_in(bundled, ["unsigned", "m.relations", "m.annotation", "chunk"])
      assert [%{"key" => "👍", "count" => 2}] = chunk
    end

    test "bundles m.thread with the latest reply and participation flag" do
      root = event(%{"content" => %{"body" => "thread root"}})
      {:ok, _} = EventStore.insert_event(root, "10")

      {:ok, _} =
        EventStore.insert_event(
          event(%{"sender" => "@replier:localhost", "content" => %{"body" => "reply 1", "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => root["event_id"]}}}),
          "10"
        )

      [bundled] = EventStore.bundle_relations(@room, [root], user_id: "@replier:localhost")
      thread = get_in(bundled, ["unsigned", "m.relations", "m.thread"])
      assert thread["count"] == 1
      assert thread["current_user_participated"] == true
    end

    test "generic rel_types (e.g. m.reference, used by polls) get a plain count bundle" do
      root = event(%{"content" => %{"body" => "poll start"}})
      {:ok, _} = EventStore.insert_event(root, "10")

      {:ok, _} =
        EventStore.insert_event(
          event(%{"content" => %{"m.relates_to" => %{"rel_type" => "m.reference", "event_id" => root["event_id"]}}}),
          "10"
        )

      [bundled] = EventStore.bundle_relations(@room, [root])
      assert get_in(bundled, ["unsigned", "m.relations", "m.reference"]) == %{"count" => 1}
    end

    test "an event with no children is returned unchanged" do
      lonely = event()
      {:ok, _} = EventStore.insert_event(lonely, "10")
      [bundled] = EventStore.bundle_relations(@room, [lonely])
      assert bundled == lonely
    end
  end

  describe "membership queries" do
    test "get_joined_rooms / get_invited_rooms / get_knocked_rooms filter correctly" do
      alice = "@alice_membership:localhost"
      insert_user(alice)

      {:ok, _} = EventStore.insert_event(event(%{"type" => "m.room.member", "state_key" => alice, "content" => %{"membership" => "invite"}}), "10")
      assert @room in EventStore.get_invited_rooms(alice)
      assert EventStore.get_joined_rooms(alice) == []

      {:ok, _} = EventStore.insert_event(event(%{"type" => "m.room.member", "state_key" => alice, "content" => %{"membership" => "join"}}), "10")
      assert @room in EventStore.get_joined_rooms(alice)
      assert EventStore.get_invited_rooms(alice) == []
    end

    test "get_membership returns nil (via {:ok, nil}) for a user with no membership row" do
      assert EventStore.get_membership(@room, "@nobody:localhost") == {:ok, nil}
    end

    test "get_room_members filters by membership state" do
      bob = "@bob_members:localhost"
      insert_user(bob)
      {:ok, _} = EventStore.insert_event(event(%{"type" => "m.room.member", "state_key" => @creator, "sender" => @creator, "content" => %{"membership" => "join"}}), "10")
      {:ok, _} = EventStore.insert_event(event(%{"type" => "m.room.member", "state_key" => bob, "content" => %{"membership" => "invite"}}), "10")

      joined = EventStore.get_room_members(@room, ["join"]) |> Enum.map(& &1.user_id)
      assert @creator in joined
      refute bob in joined
    end
  end

  describe "knock preview state" do
    test "set then get round-trips the stripped events" do
      knocker = "@knocker:localhost"
      insert_user(knocker)
      {:ok, _} = EventStore.insert_event(event(%{"type" => "m.room.member", "state_key" => knocker, "content" => %{"membership" => "knock"}}), "10")

      preview = [%{"type" => "m.room.name", "state_key" => "", "sender" => @creator, "content" => %{"name" => "Preview"}}]
      :ok = EventStore.set_knock_preview_state(@room, knocker, preview)

      assert EventStore.get_knock_preview_state(@room, knocker) == preview
    end

    test "no preview state stored yields an empty list" do
      assert EventStore.get_knock_preview_state(@room, "@nobody:localhost") == []
    end
  end

  describe "snapshots" do
    test "create_snapshot then latest_snapshot round-trips the state_map" do
      # EventStore itself is separator-agnostic (the type\x1Fstate_key
      # convention lives in AxonRoom.RoomProcess) — use a plain key here.
      state_map = %{"m.room.create" => "$create_event_id"}
      :ok = EventStore.create_snapshot(@room, 5, state_map)

      assert %{after_stream_ordering: 5, state_map: ^state_map} = EventStore.latest_snapshot(@room)
    end

    test "latest_snapshot picks the highest after_stream_ordering" do
      :ok = EventStore.create_snapshot(@room, 1, %{})
      :ok = EventStore.create_snapshot(@room, 10, %{"a" => "b"})

      assert %{after_stream_ordering: 10} = EventStore.latest_snapshot(@room)
    end

    test "no snapshot yields nil" do
      assert EventStore.latest_snapshot("!nosnap:localhost") == nil
    end
  end

  describe "room_exists?/1" do
    test "true for a room that was created" do
      assert EventStore.room_exists?(@room)
    end

    test "false for one that wasn't" do
      refute EventStore.room_exists?("!never:localhost")
    end
  end
end
