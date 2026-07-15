defmodule AxonRoom.StateResV2Test do
  @moduledoc """
  Direct, pure-function unit tests for `AxonRoom.StateResV2` using hand-built
  event DAGs (no DB — a plain in-memory map stands in for `get_event_fn`).

  Note on tie-break direction: for events tied on mainline power position,
  the exact depth-tiebreak direction (does the older or newer event win a
  true tie?) is pinned here as *current, observed* behavior rather than
  asserted as spec-correct — full confidence there needs a cross-check
  against a reference implementation (Synapse) or Complement's state-res
  vectors, which is out of scope for this pass. Flagged in the findings list.
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

  test "keys that don't conflict across state sets pass through untouched" do
    create = create_event()
    joined = member_event("$m1", @alice, "join", 1, ["$create"])

    set_a = %{{"m.room.create", ""} => create}
    set_b = %{{"m.room.create", ""} => create, {"m.room.member", @alice} => joined}

    resolved = StateResV2.resolve([set_a, set_b], fn _ -> nil end)

    assert resolved[{"m.room.create", ""}] == create
    assert resolved[{"m.room.member", @alice}] == joined
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
  end
end
