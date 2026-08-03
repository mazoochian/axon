defmodule AxonRoom.StateResV2Test do
  @moduledoc """
  Direct, pure-function unit tests for `AxonRoom.StateResV2` using hand-built
  event DAGs (no DB — a plain in-memory map stands in for `get_event_fn`).

  Tie-break direction (events tied on mainline power position resolve by
  depth, newer wins) is verified against the spec's own wording
  (`spec.matrix.org/v1.16/rooms/v2/`: ties resolve with the *newer* event
  winning) — see "a 3-generation fork resolves deterministically to the
  newer branch, not an ancestor" below, which also regression-covers a
  real bug this verification found: the sort key used `-depth`
  (descending), the opposite of the documented intent, letting an older
  ancestor pulled into the replay set via auth_diff outrank its own newer
  descendants. Every conflict test before that one used only
  two-generation fixtures, so the bug was latent until real
  multi-generation forks became reachable (`AxonRoom.StateResolver` doing
  genuine DAG replay instead of a one-hop peek).
  """

  use ExUnit.Case, async: true

  alias AxonRoom.StateResV2

  @creator "@creator:localhost"
  @alice "@alice:localhost"

  defp events_store, do: :ets.new(:events, [:set, :public])

  defp put_event(store, event) do
    :ets.insert(store, {event["event_id"], event})
    event
  end

  defp get_event_fn(store),
    do: fn id ->
      case :ets.lookup(store, id) do
        [{^id, e}] -> e
        [] -> nil
      end
    end

  defp create_event do
    %{
      "event_id" => "$create",
      "type" => "m.room.create",
      "state_key" => "",
      "sender" => @creator,
      "depth" => 0,
      "auth_events" => [],
      "content" => %{"creator" => @creator}
    }
  end

  defp member_event(id, user_id, membership, depth, auth_events) do
    %{
      "event_id" => id,
      "type" => "m.room.member",
      "state_key" => user_id,
      "sender" => user_id,
      "depth" => depth,
      "auth_events" => auth_events,
      "content" => %{"membership" => membership}
    }
  end

  defp topic_event(id, sender, depth, auth_events, topic) do
    %{
      "event_id" => id,
      "type" => "m.room.topic",
      "state_key" => "",
      "sender" => sender,
      "depth" => depth,
      "auth_events" => auth_events,
      "content" => %{"topic" => topic}
    }
  end

  defp pl_event(id, sender, depth, auth_events, users) do
    %{
      "event_id" => id,
      "type" => "m.room.power_levels",
      "state_key" => "",
      "sender" => sender,
      "depth" => depth,
      "auth_events" => auth_events,
      "content" => %{"users" => users}
    }
  end

  # ---------------------------------------------------------------------------
  # Trivial cases
  # ---------------------------------------------------------------------------

  test "resolving zero state sets yields an empty state" do
    assert StateResV2.resolve([], fn _ -> nil end) == %{}
  end

  test "resolving a single state set returns it unchanged" do
    single = %{{"m.room.create", ""} => create_event()}
    assert StateResV2.resolve([single], fn _ -> nil end) == single
  end

  test "a key present with the same value in every state set passes through untouched (genuinely unconflicted)" do
    create = create_event()
    joined = member_event("$m1", @alice, "join", 1, ["$create"])

    set_a = %{{"m.room.create", ""} => create, {"m.room.member", @alice} => joined}
    set_b = %{{"m.room.create", ""} => create, {"m.room.member", @alice} => joined}

    resolved = StateResV2.resolve([set_a, set_b], fn _ -> nil end)

    assert resolved[{"m.room.create", ""}] == create
    assert resolved[{"m.room.member", @alice}] == joined
  end

  # Per spec, a key present in only *some* input state sets is conflicted,
  # not unconflicted — the sets lacking an opinion don't get to wave the
  # sole candidate value through without an auth check. Getting this wrong
  # meant a value could reach the resolved state having never once been
  # checked against AuthRules.
  describe "a key present in only some state sets is conflicted" do
    test "a legitimately-authorized single-branch value still survives" do
      create = create_event()
      # The room creator's own join is authorized unconditionally (initial
      # join before join_rules exists) regardless of join_rule, so this
      # must survive the now-mandatory auth check.
      creator_join = member_event("$m1", @creator, "join", 1, [create["event_id"]])

      set_a = %{{"m.room.create", ""} => create}
      set_b = %{{"m.room.create", ""} => create, {"m.room.member", @creator} => creator_join}

      resolved = StateResV2.resolve([set_a, set_b], fn _ -> nil end)

      assert resolved[{"m.room.member", @creator}] == creator_join
    end

    test "a value that would fail auth is dropped, not waved through" do
      create = create_event()
      # join_rule defaults to "invite" and alice is neither invited nor the
      # creator, so this join is illegitimate even though it's the only
      # candidate for its key.
      uninvited_join = member_event("$m1", @alice, "join", 1, [create["event_id"]])

      set_a = %{{"m.room.create", ""} => create}
      set_b = %{{"m.room.create", ""} => create, {"m.room.member", @alice} => uninvited_join}

      resolved = StateResV2.resolve([set_a, set_b], fn _ -> nil end)

      refute Map.has_key?(resolved, {"m.room.member", @alice})
    end
  end

  test "the same event_id appearing in multiple sets for the same key isn't treated as a conflict" do
    create = create_event()
    set_a = %{{"m.room.create", ""} => create}
    set_b = %{{"m.room.create", ""} => create}

    assert StateResV2.resolve([set_a, set_b], fn _ -> nil end) == %{
             {"m.room.create", ""} => create
           }
  end

  # ---------------------------------------------------------------------------
  # Genuine conflicts
  # ---------------------------------------------------------------------------

  describe "conflicting non-power state" do
    setup do
      store = events_store()
      create = put_event(store, create_event())
      joined = put_event(store, member_event("$m1", @alice, "join", 1, [create["event_id"]]))
      # Grants alice (state_default is otherwise 50, users default 0) enough
      # power to send state events, so her topic changes pass AuthRules.check.
      pl =
        put_event(
          store,
          pl_event("$pl0", @creator, 1, [create["event_id"]], %{@creator => 100, @alice => 50})
        )

      unconflicted = %{
        {"m.room.create", ""} => create,
        {"m.room.member", @alice} => joined,
        {"m.room.power_levels", ""} => pl
      }

      %{store: store, create: create, joined: joined, unconflicted: unconflicted}
    end

    test "resolves to exactly one of two conflicting topic events, both authorized",
         %{store: store, create: create, joined: joined, unconflicted: unconflicted} do
      topic_a =
        put_event(
          store,
          topic_event("$ta", @alice, 2, [create["event_id"], joined["event_id"]], "Topic A")
        )

      topic_b =
        put_event(
          store,
          topic_event("$tb", @alice, 3, [create["event_id"], joined["event_id"]], "Topic B")
        )

      set_a = Map.put(unconflicted, {"m.room.topic", ""}, topic_a)
      set_b = Map.put(unconflicted, {"m.room.topic", ""}, topic_b)

      resolved = StateResV2.resolve([set_a, set_b], get_event_fn(store))

      winner = resolved[{"m.room.topic", ""}]
      assert winner["event_id"] in ["$ta", "$tb"]
      # Deterministic: re-resolving the same input always yields the same winner.
      assert StateResV2.resolve([set_a, set_b], get_event_fn(store))[{"m.room.topic", ""}] ==
               winner
    end

    test "an event that fails the auth check is never the resolved winner",
         %{store: store, create: create, joined: joined, unconflicted: unconflicted} do
      # A topic event from a user who was never a member of the room — always
      # fails AuthRules.check (not_joined) regardless of ordering, so the
      # *other* conflicting candidate must win instead.
      valid_topic =
        put_event(
          store,
          topic_event("$tv", @alice, 2, [create["event_id"], joined["event_id"]], "Valid")
        )

      invalid_topic =
        put_event(
          store,
          topic_event("$ti", "@intruder:localhost", 5, [create["event_id"]], "Invalid")
        )

      set_a = Map.put(unconflicted, {"m.room.topic", ""}, valid_topic)
      set_b = Map.put(unconflicted, {"m.room.topic", ""}, invalid_topic)

      resolved = StateResV2.resolve([set_a, set_b], get_event_fn(store))
      assert resolved[{"m.room.topic", ""}]["event_id"] == "$tv"
    end

    test "if neither conflicting candidate passes the auth check, the key is simply absent from the result",
         %{store: store, create: create} do
      bad1 =
        put_event(
          store,
          topic_event("$b1", "@intruder1:localhost", 1, [create["event_id"]], "Bad1")
        )

      bad2 =
        put_event(
          store,
          topic_event("$b2", "@intruder2:localhost", 2, [create["event_id"]], "Bad2")
        )

      unconflicted = %{{"m.room.create", ""} => create}
      set_a = Map.put(unconflicted, {"m.room.topic", ""}, bad1)
      set_b = Map.put(unconflicted, {"m.room.topic", ""}, bad2)

      resolved = StateResV2.resolve([set_a, set_b], get_event_fn(store))
      refute Map.has_key?(resolved, {"m.room.topic", ""})
    end
  end

  describe "conflicting power_levels" do
    test "resolves to exactly one of the conflicting power_levels events" do
      store = events_store()
      create = put_event(store, create_event())

      creator_joined =
        put_event(store, member_event("$mc", @creator, "join", 1, [create["event_id"]]))

      pl_a =
        put_event(store, pl_event("$pla", @creator, 2, [create["event_id"]], %{@creator => 100}))

      pl_b =
        put_event(
          store,
          pl_event("$plb", @creator, 3, [create["event_id"]], %{@creator => 100, @alice => 50})
        )

      unconflicted = %{
        {"m.room.create", ""} => create,
        {"m.room.member", @creator} => creator_joined
      }

      set_a = Map.put(unconflicted, {"m.room.power_levels", ""}, pl_a)
      set_b = Map.put(unconflicted, {"m.room.power_levels", ""}, pl_b)

      resolved = StateResV2.resolve([set_a, set_b], get_event_fn(store))
      winner = resolved[{"m.room.power_levels", ""}]
      assert winner["event_id"] in ["$pla", "$plb"]
    end

    test "a 3-generation fork resolves deterministically to the newer branch, not an ancestor" do
      # Both candidates descend from a shared *second*-generation power_levels
      # event (pl_mid), not directly from create — regression coverage for a
      # real, previously-latent bug: reverse_topological_power_ordering used
      # to sort tied power events by depth *descending*, so an older
      # ancestor pulled into the replay set via auth_diff could win over its
      # own newer descendants. Every conflict test before this one used only
      # two-generation fixtures (both candidates direct children of the same
      # root), so the bug never triggered.
      store = events_store()
      create = put_event(store, create_event())

      creator_joined =
        put_event(store, member_event("$mc3", @creator, "join", 1, [create["event_id"]]))

      alice_joined =
        put_event(store, member_event("$ma3", @alice, "join", 1, [create["event_id"]]))

      _pl_mid =
        put_event(
          store,
          pl_event("$plmid", @creator, 2, [create["event_id"]], %{@creator => 100, @alice => 100})
        )

      pl_a =
        put_event(
          store,
          pl_event("$pla3", @alice, 3, [create["event_id"], "$plmid"], %{
            @creator => 100,
            @alice => 100
          })
        )

      pl_b =
        put_event(
          store,
          pl_event("$plb3", @alice, 4, [create["event_id"], "$plmid"], %{
            @creator => 100,
            @alice => 100
          })
        )

      unconflicted = %{
        {"m.room.create", ""} => create,
        {"m.room.member", @creator} => creator_joined,
        {"m.room.member", @alice} => alice_joined
      }

      set_a = Map.put(unconflicted, {"m.room.power_levels", ""}, pl_a)
      set_b = Map.put(unconflicted, {"m.room.power_levels", ""}, pl_b)

      resolved = StateResV2.resolve([set_a, set_b], get_event_fn(store))
      winner = resolved[{"m.room.power_levels", ""}]

      # pl_b (depth 4, the newer of the two tied-mainline-position siblings)
      # must win — and critically, the shared ancestor pl_mid (depth 2) must
      # never win despite being pulled into the replay set via auth_diff.
      assert winner["event_id"] == "$plb3"
    end
  end

  describe "conflicted state subgraph (room v12 only)" do
    test "an intermediate power_levels event needed to authorize the winner is included via the subgraph" do
      # Shape: pl0 -> plz (branch Z's tip) -> m (grants alice power, using
      # plz's own authority) -> ply2 (branch Y's tip, sent by alice using
      # m's grant). plz is directly in m's auth_events, so m genuinely lies
      # on a path between the two conflicted-set events (ply2 and plz) —
      # not merely a shared ancestor of one, which auth_diff already
      # handles. Without the subgraph, m gets excluded from the replay set
      # (it's also reachable from the unconflicted topic event's own
      # ancestry, so auth_diff subtracts it) even though ply2 cannot pass
      # AuthRules.check without it: ply2's sender (alice) only has power
      # because of m specifically, not plz or pl0 alone.
      store = events_store()
      creator = @creator
      bob = "@bob:localhost"
      alice = @alice

      create = put_event(store, create_event())
      creator_joined = put_event(store, member_event("$cj", creator, "join", 1, ["$create"]))
      bob_joined = put_event(store, member_event("$bj", bob, "join", 1, ["$create"]))
      alice_joined = put_event(store, member_event("$aj", alice, "join", 1, ["$create"]))

      _pl0 =
        put_event(
          store,
          %{
            "event_id" => "$pl0",
            "type" => "m.room.power_levels",
            "state_key" => "",
            "sender" => creator,
            "depth" => 2,
            "auth_events" => ["$create", "$cj"],
            "content" => %{"users" => %{bob => 100}, "state_default" => 100}
          }
        )

      plz =
        put_event(
          store,
          %{
            "event_id" => "$plz",
            "type" => "m.room.power_levels",
            "state_key" => "",
            "sender" => bob,
            "depth" => 3,
            "auth_events" => ["$create", "$cj", "$bj", "$pl0"],
            "content" => %{"users" => %{bob => 100}, "state_default" => 100, "ban" => 50}
          }
        )

      _m =
        put_event(
          store,
          %{
            "event_id" => "$m",
            "type" => "m.room.power_levels",
            "state_key" => "",
            "sender" => bob,
            "depth" => 4,
            "auth_events" => ["$create", "$cj", "$bj", "$plz"],
            "content" => %{"users" => %{bob => 100, alice => 100}, "state_default" => 100}
          }
        )

      ply2 =
        put_event(
          store,
          %{
            "event_id" => "$ply2",
            "type" => "m.room.power_levels",
            "state_key" => "",
            "sender" => alice,
            "depth" => 5,
            "auth_events" => ["$create", "$cj", "$aj", "$m"],
            "content" => %{"users" => %{bob => 100}, "state_default" => 100, "ban" => 75}
          }
        )

      topic =
        put_event(
          store,
          topic_event("$u", bob, 5, ["$create", "$cj", "$bj", "$m"], "shared")
        )

      unconflicted = %{
        {"m.room.create", ""} => create,
        {"m.room.member", creator} => creator_joined,
        {"m.room.member", bob} => bob_joined,
        {"m.room.member", alice} => alice_joined,
        {"m.room.topic", ""} => topic
      }

      set_a = Map.put(unconflicted, {"m.room.power_levels", ""}, ply2)
      set_b = Map.put(unconflicted, {"m.room.power_levels", ""}, plz)

      v11 = StateResV2.resolve([set_a, set_b], get_event_fn(store), "11")
      v12 = StateResV2.resolve([set_a, set_b], get_event_fn(store), "12")

      # v11 has no subgraph concept: m gets excluded, alice's authority is
      # invisible during replay, ply2 fails its auth check, and the room
      # incorrectly stays on the older plz.
      assert v11[{"m.room.power_levels", ""}]["event_id"] == "$plz"

      # v12: the subgraph correctly pulls m into the replay set, alice's
      # power is visible when ply2 is checked, and the actually-latest,
      # properly-authorized event wins.
      assert v12[{"m.room.power_levels", ""}]["event_id"] == "$ply2"
    end
  end

  describe "v12 starts iterative auth checks from an empty set (MSC4297)" do
    test "a genuinely unconflicted membership event is still visible during replay, via auth_events fallback" do
      # This is what distinguishes v12 from v11 here: v11's check_state is
      # `Map.merge(unconflicted, resolved_so_far)` at every step, so an
      # unconflicted sender-membership event is trivially visible even with
      # no fallback at all. v12 deliberately does NOT do that merge during
      # replay (`check_state = resolved_so_far`, unconflicted only folds
      # back in once, after the whole iteration finishes) — so the *only*
      # thing that can make the creator's own (genuinely unconflicted, and
      # therefore never itself part of the replay set) join event visible
      # while checking a conflicting join_rules candidate is
      # `with_auth_event_fallback/3` walking that candidate's own
      # `auth_events`. Without it, `check_sender_joined` sees no member
      # state at all, both conflicting candidates spuriously fail
      # AuthRules.check, and m.room.join_rules would vanish from the
      # resolved state entirely instead of correctly picking the newer
      # candidate.
      store = events_store()
      creator = @creator

      create = put_event(store, create_event())
      creator_joined = put_event(store, member_event("$cj", creator, "join", 1, ["$create"]))

      jr_older =
        put_event(store, %{
          "event_id" => "$jr_older",
          "type" => "m.room.join_rules",
          "state_key" => "",
          "sender" => creator,
          "depth" => 2,
          "auth_events" => ["$create", "$cj"],
          "content" => %{"join_rule" => "invite"}
        })

      jr_newer =
        put_event(store, %{
          "event_id" => "$jr_newer",
          "type" => "m.room.join_rules",
          "state_key" => "",
          "sender" => creator,
          "depth" => 3,
          "auth_events" => ["$create", "$cj"],
          "content" => %{"join_rule" => "public"}
        })

      unconflicted = %{
        {"m.room.create", ""} => create,
        {"m.room.member", creator} => creator_joined
      }

      set_a = Map.put(unconflicted, {"m.room.join_rules", ""}, jr_older)
      set_b = Map.put(unconflicted, {"m.room.join_rules", ""}, jr_newer)

      v12 = StateResV2.resolve([set_a, set_b], get_event_fn(store), "12")

      # Both candidates need the fallback to pass AuthRules.check at all
      # (no PL event exists, so the creator's authority to send
      # m.room.join_rules comes entirely from v12's implicit
      # infinite-power-for-creators rule, which still requires
      # check_sender_joined to see the creator's own membership first) —
      # if the key were simply missing, this would already demonstrate the
      # bug. Asserting the *newer* event specifically also re-confirms the
      # depth tie-break direction this module fixed elsewhere.
      assert v12[{"m.room.join_rules", ""}]["event_id"] == "$jr_newer"
    end
  end
end
