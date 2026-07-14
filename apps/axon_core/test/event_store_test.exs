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
      [
        %{
          user_id: user_id,
          localpart: localpart,
          is_guest: false,
          deactivated: false,
          admin: false,
          inserted_at: now,
          updated_at: now
        }
      ],
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
        EventStore.get_events_since(@room, 0, 1000)
        |> Enum.count(&(&1.event_id == ev["event_id"]))

      assert count == 1
    end

    test "a state event materializes into current_room_state" do
      ev = event(%{"type" => "m.room.name", "state_key" => "", "content" => %{"name" => "Hello"}})
      assert {:ok, _} = EventStore.insert_event(ev, "10")

      assert {:ok, state_event} = EventStore.get_state_event(@room, "m.room.name", "")
      assert state_event.content["name"] == "Hello"
    end

    test "a later state event for the same key replaces the earlier one in current_room_state" do
      ev1 =
        event(%{
          "type" => "m.room.topic",
          "state_key" => "",
          "content" => %{"topic" => "v1"},
          "depth" => 1
        })

      ev2 =
        event(%{
          "type" => "m.room.topic",
          "state_key" => "",
          "content" => %{"topic" => "v2"},
          "depth" => 2
        })

      {:ok, _} = EventStore.insert_event(ev1, "10")
      {:ok, _} = EventStore.insert_event(ev2, "10")

      assert {:ok, state_event} = EventStore.get_state_event(@room, "m.room.topic", "")
      assert state_event.content["topic"] == "v2"
    end

    test "a membership event derives a room_memberships row" do
      ev =
        event(%{
          "type" => "m.room.member",
          "state_key" => @creator,
          "sender" => @creator,
          "content" => %{"membership" => "join"}
        })

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

    test "get_events_since returns events in ascending order after the given ordering", %{
      base: base,
      p1: p1,
      p2: p2,
      p3: p3
    } do
      events = EventStore.get_events_since(@room, base, 10)
      assert Enum.map(events, & &1.event_id) == [p1.event_id, p2.event_id, p3.event_id]
    end

    test "get_events_since respects the limit", %{base: base} do
      assert length(EventStore.get_events_since(@room, base, 2)) == 2
    end

    test "get_messages backwards (dir=b) returns newest-first before the given ordering", %{
      p3: p3
    } do
      [first | _] = EventStore.get_messages(@room, p3.stream_ordering + 1, "b", 10)
      assert first.event_id == p3.event_id
    end

    test "get_messages forwards (dir=f) returns oldest-first after the given ordering", %{
      base: base,
      p1: p1
    } do
      [first | _] = EventStore.get_messages(@room, base, "f", 10)
      assert first.event_id == p1.event_id
    end
  end

  describe "search_messages" do
    test "finds a message by body text and reports a total count" do
      {:ok, _} =
        EventStore.insert_event(
          event(%{"content" => %{"msgtype" => "m.text", "body" => "the quick brown fox"}}),
          "10"
        )

      {:ok, _} =
        EventStore.insert_event(
          event(%{"content" => %{"msgtype" => "m.text", "body" => "unrelated message"}}),
          "10"
        )

      {hits, count} = EventStore.search_messages([@room], "quick fox", "rank", 10)
      assert count == 1
      assert [{event_id, _rank}] = hits
      assert is_binary(event_id)
    end

    test "returns no hits for a non-matching term" do
      {:ok, _} =
        EventStore.insert_event(
          event(%{"content" => %{"msgtype" => "m.text", "body" => "hello world"}}),
          "10"
        )

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
              "content" => %{
                "m.relates_to" => %{
                  "rel_type" => "m.annotation",
                  "event_id" => target["event_id"],
                  "key" => "👍"
                }
              }
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
          event(%{
            "sender" => "@replier:localhost",
            "content" => %{
              "body" => "reply 1",
              "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => root["event_id"]}
            }
          }),
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
          event(%{
            "content" => %{
              "m.relates_to" => %{"rel_type" => "m.reference", "event_id" => root["event_id"]}
            }
          }),
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

      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => alice,
            "content" => %{"membership" => "invite"}
          }),
          "10"
        )

      assert @room in EventStore.get_invited_rooms(alice)
      assert EventStore.get_joined_rooms(alice) == []

      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => alice,
            "content" => %{"membership" => "join"}
          }),
          "10"
        )

      assert @room in EventStore.get_joined_rooms(alice)
      assert EventStore.get_invited_rooms(alice) == []
    end

    test "get_membership returns nil (via {:ok, nil}) for a user with no membership row" do
      assert EventStore.get_membership(@room, "@nobody:localhost") == {:ok, nil}
    end

    test "get_room_members filters by membership state" do
      bob = "@bob_members:localhost"
      insert_user(bob)

      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => @creator,
            "sender" => @creator,
            "content" => %{"membership" => "join"}
          }),
          "10"
        )

      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => bob,
            "content" => %{"membership" => "invite"}
          }),
          "10"
        )

      joined = EventStore.get_room_members(@room, ["join"]) |> Enum.map(& &1.user_id)
      assert @creator in joined
      refute bob in joined
    end
  end

  describe "knock preview state" do
    test "set then get round-trips the stripped events" do
      knocker = "@knocker:localhost"
      insert_user(knocker)

      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => knocker,
            "content" => %{"membership" => "knock"}
          }),
          "10"
        )

      preview = [
        %{
          "type" => "m.room.name",
          "state_key" => "",
          "sender" => @creator,
          "content" => %{"name" => "Preview"}
        }
      ]

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

      assert %{after_stream_ordering: 5, state_map: ^state_map} =
               EventStore.latest_snapshot(@room)
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

  describe "get_event/1" do
    test "returns {:error, :not_found} for an unknown event_id" do
      assert EventStore.get_event("$nope") == {:error, :not_found}
    end
  end

  describe "event_to_map_by_id/1 and get_event_map/1" do
    test "both round-trip a persisted event to its wire map" do
      ev = event()
      {:ok, _} = EventStore.insert_event(ev, "10")

      assert EventStore.event_to_map_by_id(ev["event_id"])["event_id"] == ev["event_id"]
      assert EventStore.get_event_map(ev["event_id"])["event_id"] == ev["event_id"]
    end

    test "both return nil for an unknown event_id" do
      assert EventStore.event_to_map_by_id("$nope") == nil
      assert EventStore.get_event_map("$nope") == nil
    end
  end

  describe "event_to_map/1 room v12 room_id omission" do
    test "a v12 m.room.create event has no room_id on the wire" do
      v12_room = "!v12room:localhost"
      {:ok, _} = EventStore.insert_room(v12_room, @creator, "12", false)

      ev =
        event(%{
          "room_id" => v12_room,
          "type" => "m.room.create",
          "state_key" => "",
          "content" => %{"room_version" => "12"}
        })

      {:ok, persisted} = EventStore.insert_event(ev, "12")
      wire_map = EventStore.event_to_map(persisted)

      refute Map.has_key?(wire_map, "room_id")
    end

    test "a non-create v12 event keeps its room_id" do
      v12_room = "!v12room2:localhost"
      {:ok, _} = EventStore.insert_room(v12_room, @creator, "12", false)

      ev = event(%{"room_id" => v12_room})
      {:ok, persisted} = EventStore.insert_event(ev, "12")
      wire_map = EventStore.event_to_map(persisted)

      assert wire_map["room_id"] == v12_room
    end

    test "a v11 create event keeps its room_id" do
      ev =
        event(%{
          "type" => "m.room.create",
          "state_key" => "",
          "content" => %{"room_version" => "10"}
        })

      {:ok, persisted} = EventStore.insert_event(ev, "10")
      wire_map = EventStore.event_to_map(persisted)

      assert wire_map["room_id"] == @room
    end
  end

  describe "get_relations/7" do
    setup do
      target = event(%{"content" => %{"body" => "target"}})
      {:ok, _target_p} = EventStore.insert_event(target, "10")

      {:ok, reaction_p} =
        EventStore.insert_event(
          event(%{
            "type" => "m.reaction",
            "content" => %{
              "m.relates_to" => %{
                "rel_type" => "m.annotation",
                "event_id" => target["event_id"],
                "key" => "👍"
              }
            }
          }),
          "10"
        )

      {:ok, thread_p} =
        EventStore.insert_event(
          event(%{
            "content" => %{
              "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => target["event_id"]}
            }
          }),
          "10"
        )

      %{target: target, reaction: reaction_p, thread: thread_p}
    end

    test "returns only events related to the target", %{target: target, reaction: reaction} do
      results = EventStore.get_relations(@room, target["event_id"], nil, nil, 0, "f", 10)
      assert Enum.any?(results, &(&1.event_id == reaction.event_id))
    end

    test "filters by rel_type", %{target: target, reaction: reaction, thread: thread} do
      results =
        EventStore.get_relations(@room, target["event_id"], "m.annotation", nil, 0, "f", 10)

      ids = Enum.map(results, & &1.event_id)

      assert reaction.event_id in ids
      refute thread.event_id in ids
    end

    test "filters by event_type", %{target: target, reaction: reaction} do
      results = EventStore.get_relations(@room, target["event_id"], nil, "m.reaction", 0, "f", 10)
      assert Enum.all?(results, &(&1.event_id == reaction.event_id))
    end

    test "dir=b returns newest-first before from_ordering", %{
      target: target,
      reaction: reaction,
      thread: thread
    } do
      results =
        EventStore.get_relations(
          @room,
          target["event_id"],
          nil,
          nil,
          thread.stream_ordering + 1,
          "b",
          10
        )

      assert hd(results).event_id == thread.event_id
      assert Enum.any?(results, &(&1.event_id == reaction.event_id))
    end

    test "an unrelated event is never returned" do
      {:ok, _} = EventStore.insert_event(event(%{"content" => %{"body" => "unrelated"}}), "10")
      results = EventStore.get_relations(@room, "$totally-unrelated", nil, nil, 0, "f", 10)
      assert results == []
    end
  end

  describe "get_current_state_map/1" do
    test "returns state keyed by {type, state_key}" do
      {:ok, _} =
        EventStore.insert_event(
          event(%{"type" => "m.room.name", "state_key" => "", "content" => %{"name" => "Room"}}),
          "10"
        )

      state = EventStore.get_current_state_map(@room)
      assert %{"name" => "Room"} = state[{"m.room.name", ""}]["content"]
    end

    test "empty for a room with no state events" do
      other_room = "!nostate:localhost"
      {:ok, _} = EventStore.insert_room(other_room, @creator, "10", false)
      assert EventStore.get_current_state_map(other_room) == %{}
    end
  end

  describe "room_recency_map/1" do
    test "maps each room to its max stream_ordering" do
      room2 = "!recency2:localhost"
      {:ok, _} = EventStore.insert_room(room2, @creator, "10", false)
      {:ok, p1} = EventStore.insert_event(event(), "10")
      {:ok, p2} = EventStore.insert_event(event(%{"room_id" => room2}), "10")

      map = EventStore.room_recency_map([@room, room2])
      assert map[@room] == p1.stream_ordering
      assert map[room2] == p2.stream_ordering
    end

    test "a room with no events is simply absent from the map" do
      empty_room = "!empty:localhost"
      {:ok, _} = EventStore.insert_room(empty_room, @creator, "10", false)
      refute Map.has_key?(EventStore.room_recency_map([empty_room]), empty_room)
    end
  end

  describe "member_counts/1" do
    test "counts joined and invited members separately" do
      bob = "@bob_counts:localhost"
      carol = "@carol_counts:localhost"
      insert_user(bob)
      insert_user(carol)

      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => @creator,
            "content" => %{"membership" => "join"}
          }),
          "10"
        )

      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => bob,
            "content" => %{"membership" => "join"}
          }),
          "10"
        )

      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => carol,
            "content" => %{"membership" => "invite"}
          }),
          "10"
        )

      assert EventStore.member_counts(@room) == %{joined: 2, invited: 1}
    end

    test "an empty room has zero counts" do
      empty_room = "!emptycounts:localhost"
      {:ok, _} = EventStore.insert_room(empty_room, @creator, "10", false)
      assert EventStore.member_counts(empty_room) == %{joined: 0, invited: 0}
    end
  end

  describe "known_user?/1" do
    test "true for a user joined to any known room" do
      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => @creator,
            "content" => %{"membership" => "join"}
          }),
          "10"
        )

      assert EventStore.known_user?(@creator)
    end

    test "false for a user with no membership anywhere" do
      refute EventStore.known_user?("@stranger:localhost")
    end
  end

  describe "remote_servers_for_room/1 and remote_servers_for_user/1" do
    test "lists distinct remote server names of joined members, excluding local" do
      remote1 = "@alice:remote-a.example"
      remote2 = "@bob:remote-b.example"
      insert_user(remote1)
      insert_user(remote2)

      for user_id <- [@creator, remote1, remote2] do
        {:ok, _} =
          EventStore.insert_event(
            event(%{
              "type" => "m.room.member",
              "state_key" => user_id,
              "content" => %{"membership" => "join"}
            }),
            "10"
          )
      end

      servers = EventStore.remote_servers_for_room(@room)
      assert Enum.sort(servers) == ["remote-a.example", "remote-b.example"]

      user_servers = EventStore.remote_servers_for_user(@creator)
      assert Enum.sort(user_servers) == ["remote-a.example", "remote-b.example"]
    end

    test "remote_servers_for_user excludes the user's own server even if listed elsewhere" do
      assert EventStore.remote_servers_for_user(@creator) == []
    end
  end

  describe "record_ephemeral_update/1" do
    test "wakes a subscriber on the room's PubSub topic" do
      Phoenix.PubSub.subscribe(Axon.PubSub, "room:#{@room}")
      EventStore.record_ephemeral_update(@room)
      assert_receive {:ephemeral, room_id} when room_id == @room
    end
  end

  describe "room_blocked?/1 and purge_room/1" do
    test "a fresh room is not blocked" do
      refute EventStore.room_blocked?(@room)
    end

    test "purge_room deletes events/state/memberships and marks the room blocked" do
      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => @creator,
            "content" => %{"membership" => "join"}
          }),
          "10"
        )

      :ok = EventStore.purge_room(@room)

      assert EventStore.room_blocked?(@room)
      assert EventStore.get_events_since(@room, 0, 1000) == []
      assert EventStore.get_current_state_map(@room) == %{}
      assert EventStore.get_membership(@room, @creator) == {:ok, nil}
      # The room row itself survives as the tombstone `blocked` lives on.
      assert {:ok, _} = EventStore.get_room(@room)
    end
  end

  describe "get_left_rooms_since/3" do
    test "reports a room the user left, ordered by when they left" do
      alice = "@alice_left:localhost"
      insert_user(alice)

      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => alice,
            "content" => %{"membership" => "join"}
          }),
          "10"
        )

      base = EventStore.room_max_stream_ordering(@room)

      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => alice,
            "content" => %{"membership" => "leave"}
          }),
          "10"
        )

      assert @room in EventStore.get_left_rooms_since(alice, base)
    end

    test "does not report a room the user never left" do
      assert EventStore.get_left_rooms_since(@creator, 0) == []
    end
  end

  describe "get_user_events_since/2 shadow-ban filtering" do
    test "hides a shadow-banned sender's non-state events from another viewer, but not from themself" do
      banned = "@banned_events:localhost"
      viewer = "@viewer_events:localhost"
      now = DateTime.utc_now(:microsecond)

      Repo.insert_all(
        "users",
        [
          %{
            user_id: banned,
            localpart: "banned_events",
            shadow_banned: true,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: {:replace, [:shadow_banned]},
        conflict_target: [:user_id]
      )

      insert_user(viewer)

      for user_id <- [banned, viewer] do
        {:ok, _} =
          EventStore.insert_event(
            event(%{
              "type" => "m.room.member",
              "state_key" => user_id,
              "content" => %{"membership" => "join"}
            }),
            "10"
          )
      end

      base = EventStore.room_max_stream_ordering(@room)

      {:ok, msg} =
        EventStore.insert_event(
          event(%{"sender" => banned, "content" => %{"body" => "spam"}}),
          "10"
        )

      viewer_events = EventStore.get_user_events_since(viewer, base)
      refute Enum.any?(Map.get(viewer_events, @room, []), &(&1.event_id == msg.event_id))

      self_events = EventStore.get_user_events_since(banned, base)
      assert Enum.any?(Map.get(self_events, @room, []), &(&1.event_id == msg.event_id))
    end

    test "does not hide a shadow-banned sender's state events (e.g. joins)" do
      banned = "@banned_state:localhost"
      now = DateTime.utc_now(:microsecond)

      Repo.insert_all(
        "users",
        [
          %{
            user_id: banned,
            localpart: "banned_state",
            shadow_banned: true,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: {:replace, [:shadow_banned]},
        conflict_target: [:user_id]
      )

      {:ok, _} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => @creator,
            "content" => %{"membership" => "join"}
          }),
          "10"
        )

      base = EventStore.room_max_stream_ordering(@room)

      {:ok, join_ev} =
        EventStore.insert_event(
          event(%{
            "type" => "m.room.member",
            "state_key" => banned,
            "sender" => banned,
            "content" => %{"membership" => "join"}
          }),
          "10"
        )

      viewer_events = EventStore.get_user_events_since(@creator, base)
      assert Enum.any?(Map.get(viewer_events, @room, []), &(&1.event_id == join_ev.event_id))
    end
  end
end
