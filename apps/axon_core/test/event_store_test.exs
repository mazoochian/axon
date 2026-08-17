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

  describe "insert_rejected_event/2" do
    test "persists the raw event marked rejected but never materializes it into state" do
      ev =
        event(%{
          "type" => "m.room.topic",
          "state_key" => "",
          "content" => %{"topic" => "should not apply"}
        })

      assert {:ok, persisted} = EventStore.insert_rejected_event(ev, "10")
      assert persisted.event_id == ev["event_id"]
      assert persisted.rejected == true

      # Stored — GET /event/{id} etc. can still see it.
      assert {:ok, fetched} = EventStore.get_event(ev["event_id"])
      assert fetched.rejected == true

      # But never applied: no current_room_state row for it.
      assert EventStore.get_state_event(@room, "m.room.topic", "") == {:error, :not_found}
    end

    test "a rejected membership event does not derive a room_memberships row" do
      bob = "@bob:remote.example"

      ev =
        event(%{
          "type" => "m.room.member",
          "state_key" => bob,
          "sender" => bob,
          "content" => %{"membership" => "join"}
        })

      assert {:ok, _} = EventStore.insert_rejected_event(ev, "10")
      assert EventStore.get_membership(@room, bob) == {:ok, nil}
    end

    test "excluded from get_events_since (i.e. what /sync draws from)" do
      ev = event()
      {:ok, _} = EventStore.insert_rejected_event(ev, "10")

      events = EventStore.get_events_since(@room, 0, 1000)
      refute Enum.any?(events, &(&1.event_id == ev["event_id"]))
    end

    test "excluded from get_current_state_map/1" do
      ev =
        event(%{"type" => "m.room.topic", "state_key" => "", "content" => %{"topic" => "nope"}})

      {:ok, _} = EventStore.insert_rejected_event(ev, "10")
      state = EventStore.get_current_state_map(@room)
      refute Map.has_key?(state, {"m.room.topic", ""})
    end

    test "never downgrades an event that was already accepted" do
      ev = event()
      {:ok, _} = EventStore.insert_event(ev, "10")

      assert {:ok, persisted} = EventStore.insert_rejected_event(ev, "10")
      assert persisted.rejected == false
    end
  end

  describe "any_rejected?/1" do
    test "false for an empty list" do
      refute EventStore.any_rejected?([])
    end

    test "false when none of the ids are rejected (or don't exist)" do
      ev = event()
      {:ok, _} = EventStore.insert_event(ev, "10")
      refute EventStore.any_rejected?([ev["event_id"], "$never-existed"])
    end

    test "true when at least one id is a stored, rejected event" do
      ev = event()
      {:ok, _} = EventStore.insert_rejected_event(ev, "10")
      assert EventStore.any_rejected?(["$unrelated", ev["event_id"]])
    end
  end

  describe "unknown_ids/1" do
    test "empty for an empty list" do
      assert EventStore.unknown_ids([]) == []
    end

    test "returns ids not stored at all, whether accepted or rejected are present or not" do
      accepted = event()
      {:ok, _} = EventStore.insert_event(accepted, "10")

      rejected = event()
      {:ok, _} = EventStore.insert_rejected_event(rejected, "10")

      assert EventStore.unknown_ids([
               accepted["event_id"],
               rejected["event_id"],
               "$never-existed"
             ]) == ["$never-existed"]
    end

    test "a rejected event counts as known, not unknown" do
      rejected = event()
      {:ok, _} = EventStore.insert_rejected_event(rejected, "10")
      assert EventStore.unknown_ids([rejected["event_id"]]) == []
    end
  end

  # Regression: GET /_matrix/client/v3/rooms/{roomId}/event/{eventId} used
  # the bare, unfiltered get_event/1 to look up the event — the only query
  # in this module with no `rejected`/`soft_failed` filter at all — so a
  # rejected (e.g. transitively, via an auth_events reference to another
  # rejected/unknown event — see AxonRoom.RoomProcess's any_rejected?/
  # unknown_ids checks) or soft-failed event was still served to clients
  # with a 200 instead of 404 (Complement:
  # TestInboundFederationRejectsEventsWithRejectedAuthEvents).
  describe "get_event/1 vs get_visible_event/1" do
    test "get_event/1 returns a rejected event (federation's GET /event and " <>
           "/event_auth chain walks intentionally still need to see it)" do
      ev = event()
      {:ok, _} = EventStore.insert_rejected_event(ev, "10")

      assert {:ok, fetched} = EventStore.get_event(ev["event_id"])
      assert fetched.rejected == true
    end

    test "get_visible_event/1 treats a rejected event as not found" do
      ev = event()
      {:ok, _} = EventStore.insert_rejected_event(ev, "10")

      assert EventStore.get_visible_event(ev["event_id"]) == {:error, :not_found}
    end

    test "get_visible_event/1 treats a soft-failed event as not found" do
      ev = event()
      {:ok, _} = EventStore.insert_soft_failed_event(ev, "10")

      assert EventStore.get_visible_event(ev["event_id"]) == {:error, :not_found}
    end

    test "get_visible_event/1 returns a normally-accepted event" do
      ev = event()
      {:ok, _} = EventStore.insert_event(ev, "10")

      assert {:ok, fetched} = EventStore.get_visible_event(ev["event_id"])
      assert fetched.event_id == ev["event_id"]
    end

    test "get_visible_event/1 is not_found for an id that was never stored at all" do
      assert EventStore.get_visible_event("$never-existed") == {:error, :not_found}
    end
  end

  describe "insert_event/2 — unrejecting a previously-rejected event" do
    test "flips rejected to false, applies state, and gets a fresh (later) stream_ordering" do
      # Mirrors TestUnrejectRejectedEvents: an event is first rejected
      # (here: directly, standing in for "its ancestor was missing"), then
      # a second, unrelated event is accepted while it's still rejected,
      # then the rejected event finally gets accepted on a later attempt.
      ev =
        event(%{
          "type" => "m.room.topic",
          "state_key" => "",
          "content" => %{"topic" => "unrejected"}
        })

      {:ok, rejected_persisted} = EventStore.insert_rejected_event(ev, "10")
      assert rejected_persisted.rejected == true
      # Not applied yet.
      assert EventStore.get_state_event(@room, "m.room.topic", "") == {:error, :not_found}

      later = event()
      {:ok, later_persisted} = EventStore.insert_event(later, "10")
      assert rejected_persisted.stream_ordering < later_persisted.stream_ordering

      {:ok, unrejected} = EventStore.insert_event(ev, "10")
      assert unrejected.rejected == false
      assert unrejected.event_id == ev["event_id"]
      # Sorts *after* the event that was already accepted while this one
      # was still rejected — otherwise it would sort before any `since`
      # token captured in the meantime and never appear as a "new" event.
      assert unrejected.stream_ordering > later_persisted.stream_ordering

      assert {:ok, state_event} = EventStore.get_state_event(@room, "m.room.topic", "")
      assert state_event.content["topic"] == "unrejected"
    end

    test "an idempotent resend of an already-accepted event does not bump its stream_ordering" do
      ev = event()
      {:ok, first} = EventStore.insert_event(ev, "10")
      {:ok, second} = EventStore.insert_event(ev, "10")

      assert first.stream_ordering == second.stream_ordering
    end
  end

  # Regression: insert_event/2's on_conflict clause unconditionally reset
  # BOTH `rejected` and `soft_failed` to false — correct for rejection
  # (that's the intentional "unreject" feature above), wrong for
  # soft-failure, which insert_soft_failed_event/2's own doc promises is a
  # permanent, one-time determination "matching Synapse's own... behavior".
  # Every caller of insert_event/2 (not just AxonRoom.RoomProcess — also
  # AxonFederation.RoomJoin/RoomKnock/RoomLeave and
  # AxonWeb.FederationController call it directly) has to see that promise
  # held, so it's enforced once here rather than trusted to every call site.
  describe "insert_event/2 — never un-soft-fails" do
    test "a soft-failed event stays soft-failed and unapplied on a later insert_event/2 call" do
      ev =
        event(%{
          "type" => "m.room.topic",
          "state_key" => "",
          "content" => %{"topic" => "should stay hidden forever"}
        })

      {:ok, soft_failed_persisted} = EventStore.insert_soft_failed_event(ev, "10")
      assert soft_failed_persisted.soft_failed == true

      assert {:ok, resend_result} = EventStore.insert_event(ev, "10")
      assert resend_result.soft_failed == true
      assert resend_result.rejected == false

      # Still never applied — the retried "accept" must not resurrect it.
      assert EventStore.get_state_event(@room, "m.room.topic", "") == {:error, :not_found}
      assert EventStore.get_visible_event(ev["event_id"]) == {:error, :not_found}
    end

    test "a soft-failed membership event still derives no room_memberships row after a resend" do
      bob = "@bob:remote.example"

      ev =
        event(%{
          "type" => "m.room.member",
          "state_key" => bob,
          "sender" => bob,
          "content" => %{"membership" => "join"}
        })

      {:ok, _} = EventStore.insert_soft_failed_event(ev, "10")
      assert {:ok, _} = EventStore.insert_event(ev, "10")

      assert EventStore.get_membership(@room, bob) == {:ok, nil}
    end

    test "does not bump stream_ordering on a resent soft-failed event" do
      ev = event()
      {:ok, first} = EventStore.insert_soft_failed_event(ev, "10")
      {:ok, second} = EventStore.insert_event(ev, "10")

      assert first.stream_ordering == second.stream_ordering
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

  # Regression for TestNetworkPartitionOrdering: a remote event can be
  # created early in the DAG (low `depth`, computed from its real
  # `prev_events` at creation time on the remote server) but only reach this
  # server — and get inserted, and thus assigned its `stream_ordering` —
  # late, after the local room head has already moved on to a higher depth.
  # Ordering dir=b purely by `desc: stream_ordering` would put that
  # late-inserted, low-depth event ahead of topologically deeper events it
  # actually precedes. Ordering by `depth` first (with `stream_ordering` only
  # as a same-depth tiebreak) fixes that.
  #
  # Uses its own room (rather than `@room`, which the "get_events_since /
  # get_messages" describe block above already seeds with three depth-1
  # events) so the expected ordering isn't entangled with unrelated fixtures.
  describe "get_messages backwards (dir=b) depth ordering" do
    @depth_room "!depth-order:localhost"

    setup do
      insert_user(@creator)
      {:ok, _room} = EventStore.insert_room(@depth_room, @creator, "10", false)
      :ok
    end

    test "orders by depth, so a late-arriving forked event with low depth doesn't jump ahead of topologically deeper events" do
      # Simulates a local chain (depth 1 -> 2 -> 3) advancing normally, then
      # a remote event forked off depth 1 (depth 2, same generation as the
      # second local event) arriving and being inserted last — after the
      # depth-3 event — so it gets the highest stream_ordering of the four
      # despite its low depth.
      d1 =
        event(%{
          "room_id" => @depth_room,
          "content" => %{"body" => "local depth 1"},
          "depth" => 1
        })

      d2 =
        event(%{
          "room_id" => @depth_room,
          "content" => %{"body" => "local depth 2"},
          "depth" => 2
        })

      d3 =
        event(%{
          "room_id" => @depth_room,
          "content" => %{"body" => "local depth 3"},
          "depth" => 3
        })

      remote_forked =
        event(%{
          "room_id" => @depth_room,
          "content" => %{"body" => "late remote fork"},
          "depth" => 2
        })

      {:ok, p1} = EventStore.insert_event(d1, "10")
      {:ok, p2} = EventStore.insert_event(d2, "10")
      {:ok, p3} = EventStore.insert_event(d3, "10")
      {:ok, p4} = EventStore.insert_event(remote_forked, "10")

      # p4 has the highest stream_ordering (inserted last) but only depth 2 —
      # lower than p3's depth 3.
      assert p4.stream_ordering > p3.stream_ordering
      assert p4.depth < p3.depth

      events = EventStore.get_messages(@depth_room, p4.stream_ordering + 1, "b", 10)

      # Depth-first ordering: p3 (depth 3) first; p4 and p2 tie at depth 2,
      # broken by stream_ordering desc (p4 was inserted after p2); p1 last.
      assert Enum.map(events, & &1.event_id) == [
               p3.event_id,
               p4.event_id,
               p2.event_id,
               p1.event_id
             ]
    end
  end

  # Regression for TestJumpToDateEndpoint's "can paginate backwards" federation
  # subtests: `get_context/2` (GET /rooms/:id/context/:event_id) used to
  # reuse `get_messages/4` with the *target* event's own `stream_ordering` as
  # the pivot. That bound is `stream_ordering`-only — appropriate for
  # `get_messages/4`'s real callers, whose pivot is a pagination token
  # already established relative to a known-good window, but wrong here: the
  # target itself can be a federation-backfilled event, so a `stream_ordering`
  # comparison against *its own* value doesn't reflect DAG position any
  # better than one event's `stream_ordering` reflects another's.
  #
  # `get_context_neighbors/4` fixes this by comparing the full
  # `{depth, stream_ordering}` tuple against the target's own, not just
  # `stream_ordering`. This test reproduces the shape that broke `/context`:
  # a target event backfilled in *after* a topologically-later event was
  # already known locally (so the later event has a *lower* stream_ordering
  # than the target, despite being deeper in the DAG) — mirroring
  # `remoteCharlie`'s own join landing before the backfilled message it
  # joined after.
  describe "get_context_neighbors" do
    @context_room "!context-order:localhost"

    setup do
      insert_user(@creator)
      {:ok, _room} = EventStore.insert_room(@context_room, @creator, "10", false)
      :ok
    end

    test "bounds by depth (not stream_ordering) against the pivot event, on both sides" do
      # Insertion order (ascending stream_ordering):
      #   root (depth 1) -> future_event (depth 5, like a remote member's own
      #   join) -> ancestor (depth 2) -> target (depth 3) -- ancestor and
      #   target both backfill in *after* future_event was already known
      #   locally, exactly like Message A/B backfilling in after
      #   remoteCharlie's own join.
      root = event(%{"room_id" => @context_room, "content" => %{"body" => "root"}, "depth" => 1})

      future_event =
        event(%{"room_id" => @context_room, "content" => %{"body" => "future"}, "depth" => 5})

      ancestor =
        event(%{"room_id" => @context_room, "content" => %{"body" => "ancestor"}, "depth" => 2})

      target =
        event(%{"room_id" => @context_room, "content" => %{"body" => "target"}, "depth" => 3})

      {:ok, p_root} = EventStore.insert_event(root, "10")
      {:ok, p_future} = EventStore.insert_event(future_event, "10")
      {:ok, p_ancestor} = EventStore.insert_event(ancestor, "10")
      {:ok, p_target} = EventStore.insert_event(target, "10")

      # future_event is topologically after target (depth 5 > depth 3) but
      # was inserted locally *before* it, so it carries a lower
      # stream_ordering despite that -- the exact skew that broke the old
      # stream_ordering-only bound.
      assert p_future.stream_ordering < p_target.stream_ordering
      assert p_future.depth > p_target.depth

      before = EventStore.get_context_neighbors(@context_room, p_target, "b", 10)
      after_ = EventStore.get_context_neighbors(@context_room, p_target, "f", 10)

      # "before" is bounded by depth < target's depth: ancestor (depth 2)
      # then root (depth 1). future_event (depth 5) must NOT appear here
      # despite its lower stream_ordering -- the bug this regression pins.
      assert Enum.map(before, & &1.event_id) == [p_ancestor.event_id, p_root.event_id]

      # "after" is bounded by depth > target's depth: future_event, found
      # via its depth even though its stream_ordering is *lower* than
      # target's own -- a stream_ordering-only bound would have missed it
      # entirely.
      assert Enum.map(after_, & &1.event_id) == [p_future.event_id]
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

      {hits, count, next_offset} = EventStore.search_messages([@room], "quick fox", "rank", 10)
      assert count == 1
      assert [{event_id, _rank}] = hits
      assert is_binary(event_id)
      assert is_nil(next_offset)
    end

    test "returns no hits for a non-matching term" do
      {:ok, _} =
        EventStore.insert_event(
          event(%{"content" => %{"msgtype" => "m.text", "body" => "hello world"}}),
          "10"
        )

      assert EventStore.search_messages([@room], "zzz_no_match_zzz", "rank", 10) == {[], 0, nil}
    end

    test "an empty room list short-circuits to no hits" do
      assert EventStore.search_messages([], "anything", "rank", 10) == {[], 0, nil}
    end

    test "a full page reports a next_offset to resume from, a partial page doesn't" do
      for i <- 1..3 do
        {:ok, _} =
          EventStore.insert_event(
            event(%{"content" => %{"msgtype" => "m.text", "body" => "pagetest message #{i}"}}),
            "10"
          )
      end

      {hits, count, next_offset} =
        EventStore.search_messages([@room], "pagetest", "recent", 2)

      assert count == 3
      assert length(hits) == 2
      assert next_offset == 2

      {hits2, _count, next_offset2} =
        EventStore.search_messages([@room], "pagetest", "recent", 2, next_offset)

      assert length(hits2) == 1
      assert is_nil(next_offset2)
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

  describe "event_to_pdu_by_id/1 and get_event_map/1" do
    test "both round-trip a persisted event to its wire map" do
      ev = event()
      {:ok, _} = EventStore.insert_event(ev, "10")

      assert EventStore.event_to_pdu_by_id(ev["event_id"])["event_id"] == ev["event_id"]
      assert EventStore.get_event_map(ev["event_id"])["event_id"] == ev["event_id"]
    end

    test "both return nil for an unknown event_id" do
      assert EventStore.event_to_pdu_by_id("$nope") == nil
      assert EventStore.get_event_map("$nope") == nil
    end
  end

  # The v12 create-event room_id omission is a *federation PDU* rule only
  # (event_to_pdu/1). event_to_map/1 is the client-facing form and must
  # keep room_id — the CS API's ClientEvent schema requires it
  # unconditionally. These used to be the same function, so the client
  # form was wrongly missing it too.
  describe "event_to_pdu/1 room v12 room_id omission" do
    test "a v12 m.room.create event has no room_id in the federation PDU form, but does in the client form" do
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

      refute Map.has_key?(EventStore.event_to_pdu(persisted), "room_id")
      assert EventStore.event_to_map(persisted)["room_id"] == v12_room
    end

    test "a non-create v12 event keeps its room_id" do
      v12_room = "!v12room2:localhost"
      {:ok, _} = EventStore.insert_room(v12_room, @creator, "12", false)

      ev = event(%{"room_id" => v12_room})
      {:ok, persisted} = EventStore.insert_event(ev, "12")

      assert EventStore.event_to_map(persisted)["room_id"] == v12_room
      assert EventStore.event_to_pdu(persisted)["room_id"] == v12_room
    end

    test "a v11 create event keeps its room_id" do
      ev =
        event(%{
          "type" => "m.room.create",
          "state_key" => "",
          "content" => %{"room_version" => "10"}
        })

      {:ok, persisted} = EventStore.insert_event(ev, "10")

      assert EventStore.event_to_map(persisted)["room_id"] == @room
      assert EventStore.event_to_pdu(persisted)["room_id"] == @room
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

  describe "trustworthy_local_timestamp_answer?/3" do
    # Mirrors the shape AxonFederation.RoomJoin.import_room_state/5 produces
    # for a late-to-the-room member: it inserts events directly via
    # insert_event/2 (no DAG/auth resolution, exactly like a join's state
    # snapshot), so an event can land locally with prev_event_ids this
    # server has no record of — a "hole" that isn't necessarily this
    # server's single earliest or latest known event (see
    # AxonWeb.TimestampToEventTest's "federation" describe block for the
    # end-to-end version of this same scenario, matching Complement's
    # remoteCharlie).

    test "dir=f: the earliest known event is untrustworthy even with no gap (edge of local history)" do
      {:ok, root} = EventStore.insert_event(event(%{"prev_events" => []}), "10")
      assert EventStore.trustworthy_local_timestamp_answer?(@room, root, "f") == false
    end

    test "dir=f: a later, fully DAG-connected event is trustworthy" do
      {:ok, first} = EventStore.insert_event(event(%{"prev_events" => []}), "10")

      {:ok, second} =
        EventStore.insert_event(event(%{"prev_events" => [first.event_id]}), "10")

      assert EventStore.trustworthy_local_timestamp_answer?(@room, second, "f") == true
    end

    test "dir=f: an event isn't this server's earliest known but still has a backward gap is untrustworthy" do
      {:ok, first} = EventStore.insert_event(event(%{"prev_events" => []}), "10")

      # Inserted directly, the way a join's state snapshot would be — its
      # prev_events names an event this server was never given, so it
      # can't rule out an earlier real event in that unknown span still
      # satisfying `>= ts`.
      missing_id = "$never_stored_#{System.unique_integer([:positive])}"

      {:ok, gappy} =
        EventStore.insert_event(event(%{"prev_events" => [missing_id]}), "10")

      assert gappy.stream_ordering != EventStore.earliest_known_stream_ordering(@room)
      assert EventStore.trustworthy_local_timestamp_answer?(@room, gappy, "f") == false

      # A control case proving the check is about the gap, not merely
      # "this event": once the missing predecessor is backfilled in, the
      # same event becomes trustworthy.
      {:ok, _backfilled} =
        EventStore.insert_event(
          event(%{"event_id" => missing_id, "prev_events" => [first.event_id]}),
          "10"
        )

      assert EventStore.trustworthy_local_timestamp_answer?(@room, gappy, "f") == true
    end

    test "dir=b: the latest known event is untrustworthy (nothing can reference it forward yet)" do
      {:ok, only} = EventStore.insert_event(event(%{"prev_events" => []}), "10")
      assert EventStore.trustworthy_local_timestamp_answer?(@room, only, "b") == false
    end

    test "dir=b: an earlier event with a known successor referencing it is trustworthy" do
      {:ok, first} = EventStore.insert_event(event(%{"prev_events" => []}), "10")

      {:ok, _second} =
        EventStore.insert_event(event(%{"prev_events" => [first.event_id]}), "10")

      assert EventStore.trustworthy_local_timestamp_answer?(@room, first, "b") == true
    end

    test "dir=b: a mid-history event with no known successor is untrustworthy, even though it's neither this server's earliest nor latest known event" do
      # The exact "alice_join" shape from Complement's remoteCharlie
      # scenario: fully connected near the room's start (so it's not the
      # earliest known event), and something even later is known too (so
      # it's not the latest known event either) — but nothing locally
      # known references it going forward, because the real next event in
      # the room's history (analogous to Complement's eventA/eventB) was
      # never fetched, only this state-snapshot fragment plus a later,
      # disconnected join were.
      {:ok, root} = EventStore.insert_event(event(%{"prev_events" => []}), "10")

      {:ok, stranded} =
        EventStore.insert_event(event(%{"prev_events" => [root.event_id]}), "10")

      # Inserted directly (like a join's state snapshot), its prev_events
      # names the room's real, unknown-to-us head rather than `stranded` —
      # nothing here connects forward from `stranded`.
      missing_head_id = "$never_stored_#{System.unique_integer([:positive])}"

      {:ok, _later_disconnected} =
        EventStore.insert_event(event(%{"prev_events" => [missing_head_id]}), "10")

      assert stranded.stream_ordering != EventStore.earliest_known_stream_ordering(@room)
      refute stranded.stream_ordering == EventStore.room_max_stream_ordering(@room)
      assert EventStore.trustworthy_local_timestamp_answer?(@room, stranded, "b") == false
    end
  end
end
