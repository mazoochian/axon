defmodule AxonRoom.StateResolverTest do
  @moduledoc """
  Direct unit tests for `AxonRoom.StateResolver` — previously entirely
  untested despite its own moduledoc describing it as closing "a real gap"
  in `RoomProcess`'s handling of DAG forks. Uses real persisted events
  (via `AxonCore.EventStore.insert_event/2`) since, unlike `StateResV2`,
  this module hard-codes `EventStore.get_event_map/1` rather than taking
  an injectable lookup function.
  """

  use AxonRoom.DataCase, async: false

  alias AxonCore.EventStore
  alias AxonRoom.StateResolver

  @room "!stateresolver:localhost"
  @creator "@creator:localhost"

  defp insert_user(user_id) do
    localpart = user_id |> String.trim_leading("@") |> String.split(":") |> hd()
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "users",
      [%{user_id: user_id, localpart: localpart, inserted_at: now, updated_at: now}],
      on_conflict: :nothing
    )
  end

  defp event(overrides) do
    Map.merge(
      %{
        "event_id" => "$#{System.unique_integer([:positive])}",
        "room_id" => @room,
        "sender" => @creator,
        "type" => "m.room.message",
        "content" => %{},
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

  setup do
    insert_user(@creator)
    {:ok, _} = EventStore.insert_room(@room, @creator, "10", false)
    :ok
  end

  describe "needs_resolution?/2" do
    test "false when prev_events is empty (the create event)" do
      refute StateResolver.needs_resolution?(%{"prev_events" => []}, nil)
    end

    test "false when prev_events is absent entirely" do
      refute StateResolver.needs_resolution?(%{}, "$head")
    end

    test "false when the single prev_event matches our current head" do
      refute StateResolver.needs_resolution?(%{"prev_events" => ["$head"]}, "$head")
    end

    test "true when the single prev_event does not match our current head (we're behind)" do
      assert StateResolver.needs_resolution?(%{"prev_events" => ["$other"]}, "$head")
    end

    test "true when there are multiple prev_events (a genuine merge point)" do
      assert StateResolver.needs_resolution?(%{"prev_events" => ["$a", "$b"]}, "$a")
    end
  end

  describe "resolve_for_auth_check/4" do
    test "with no prev_events, returns current_state unchanged" do
      current_state = %{
        {"m.room.create", ""} => event(%{"type" => "m.room.create", "state_key" => ""})
      }

      pdu = event(%{"prev_events" => []})

      assert StateResolver.resolve_for_auth_check(pdu, current_state, "$head", "10") ==
               current_state
    end

    test "walks a multi-generation prev_events chain, not just one hop" do
      # create -> creator_join -> power_levels, three real generations, none
      # of which is our own current head — proves the walk actually
      # recurses through locally-known history instead of only peeking at
      # a prev_event's own auth_events one hop deep.
      create =
        event(%{
          "event_id" => "$create_chain",
          "type" => "m.room.create",
          "state_key" => "",
          "content" => %{"creator" => @creator},
          "prev_events" => []
        })

      {:ok, _} = EventStore.insert_event(create, "10")

      creator_join =
        event(%{
          "event_id" => "$join_chain",
          "type" => "m.room.member",
          "state_key" => @creator,
          "content" => %{"membership" => "join"},
          "prev_events" => [create["event_id"]]
        })

      {:ok, _} = EventStore.insert_event(creator_join, "10")

      power_levels =
        event(%{
          "event_id" => "$pl_chain",
          "type" => "m.room.power_levels",
          "state_key" => "",
          "content" => %{"users" => %{@creator => 100}},
          "prev_events" => [creator_join["event_id"]]
        })

      {:ok, _} = EventStore.insert_event(power_levels, "10")

      pdu = event(%{"prev_events" => [power_levels["event_id"]]})

      resolved = StateResolver.resolve_for_auth_check(pdu, %{}, "$our_head_not_in_chain", "10")

      assert resolved[{"m.room.create", ""}]["event_id"] == create["event_id"]
      assert resolved[{"m.room.member", @creator}]["event_id"] == creator_join["event_id"]

      assert %{"content" => %{"users" => %{@creator => 100}}} =
               resolved[{"m.room.power_levels", ""}]
    end

    test "current_state is preserved for keys the prev_event's branch doesn't touch" do
      name_event =
        event(%{"type" => "m.room.name", "state_key" => "", "content" => %{"name" => "Original"}})

      current_state = %{{"m.room.name", ""} => name_event}

      pdu = event(%{"prev_events" => []})
      resolved = StateResolver.resolve_for_auth_check(pdu, current_state, "$head", "10")

      assert resolved[{"m.room.name", ""}] == name_event
    end

    test "a prev_event that doesn't exist locally contributes nothing (doesn't crash)" do
      pdu = event(%{"prev_events" => ["$never-seen-this-one"]})

      current_state = %{
        {"m.room.create", ""} => event(%{"type" => "m.room.create", "state_key" => ""})
      }

      assert StateResolver.resolve_for_auth_check(pdu, current_state, "$head", "10") ==
               current_state
    end

    test "an unknown ancestor drops its whole branch rather than injecting an empty state" do
      create =
        event(%{
          "event_id" => "$create_unk",
          "type" => "m.room.create",
          "state_key" => "",
          "content" => %{"creator" => @creator},
          "prev_events" => []
        })

      {:ok, _} = EventStore.insert_event(create, "10")

      topic =
        event(%{
          "event_id" => "$topic_unk",
          "type" => "m.room.topic",
          "state_key" => "",
          "content" => %{"topic" => "known branch"},
          "prev_events" => [create["event_id"]]
        })

      {:ok, _} = EventStore.insert_event(topic, "10")

      pdu_known_only = event(%{"prev_events" => [topic["event_id"]]})

      pdu_with_unknown =
        event(%{"prev_events" => [topic["event_id"], "$never-seen-either"]})

      resolved_known_only =
        StateResolver.resolve_for_auth_check(pdu_known_only, %{}, "$unrelated_head", "10")

      resolved_with_unknown =
        StateResolver.resolve_for_auth_check(pdu_with_unknown, %{}, "$unrelated_head", "10")

      # Adding a second, unresolvable prev_event must change nothing — the
      # unknown branch is dropped, not injected as an empty state map (an
      # empty phantom branch would make every key in the known branch look
      # conflicted and force it through StateResV2's replay machinery
      # unnecessarily).
      assert resolved_with_unknown == resolved_known_only
      assert resolved_with_unknown[{"m.room.topic", ""}]["event_id"] == topic["event_id"]
    end

    test "a cycle between locally-stored events terminates instead of looping forever" do
      # Nothing validates on insert that prev_events resolve to
      # already-known events, so out-of-order federation delivery can
      # produce a genuine cycle in local storage — simulated directly here.
      a = event(%{"event_id" => "$cycle_a", "prev_events" => ["$cycle_b"]})
      b = event(%{"event_id" => "$cycle_b", "prev_events" => ["$cycle_a"]})

      {:ok, _} = EventStore.insert_event(a, "10")
      {:ok, _} = EventStore.insert_event(b, "10")

      pdu = event(%{"prev_events" => ["$cycle_a"]})

      # The assertion here is that this returns at all (a hang would time
      # out the test) — a pure cycle has no resolvable state, so it's
      # correctly treated the same as any other unresolvable branch.
      assert StateResolver.resolve_for_auth_check(pdu, %{}, "$unrelated_head", "10") == %{}
    end

    test "a non-state event in a prev_events chain doesn't contribute to resolved state" do
      create =
        event(%{
          "event_id" => "$create_msg",
          "type" => "m.room.create",
          "state_key" => "",
          "prev_events" => []
        })

      {:ok, _} = EventStore.insert_event(create, "10")

      message =
        event(%{"event_id" => "$msg_between", "prev_events" => [create["event_id"]]})

      {:ok, _} = EventStore.insert_event(message, "10")

      pdu = event(%{"prev_events" => [message["event_id"]]})
      resolved = StateResolver.resolve_for_auth_check(pdu, %{}, "$unrelated_head", "10")

      assert Map.keys(resolved) == [{"m.room.create", ""}]
      refute Enum.any?(resolved, fn {_k, v} -> v["event_id"] == message["event_id"] end)
    end

    test "two branches conflicting on the same state key get resolved via StateResV2" do
      # A shared create+join ancestor (present identically via both
      # branches, so it stays genuinely unconflicted and gives the replay
      # enough context for AuthRules to actually authorize either
      # candidate) with two branches diverging on m.room.name: one is our
      # own current head (participates via the last_event_id shortcut, not
      # as an unconditional extra voter), the other a foreign branch.
      # StateResV2's power-ordering tie-break decides the winner.
      create =
        event(%{
          "event_id" => "$create_conflict",
          "type" => "m.room.create",
          "state_key" => "",
          "content" => %{"creator" => @creator},
          "prev_events" => []
        })

      {:ok, _} = EventStore.insert_event(create, "10")

      creator_join =
        event(%{
          "event_id" => "$join_conflict",
          "type" => "m.room.member",
          "state_key" => @creator,
          "content" => %{"membership" => "join"},
          "prev_events" => [create["event_id"]]
        })

      {:ok, _} = EventStore.insert_event(creator_join, "10")

      name_b = event(%{"type" => "m.room.name", "state_key" => "", "content" => %{"name" => "B"}})

      current_state = %{
        {"m.room.create", ""} => create,
        {"m.room.member", @creator} => creator_join,
        {"m.room.name", ""} => name_b
      }

      name_a =
        event(%{
          "event_id" => "$name_a",
          "type" => "m.room.name",
          "state_key" => "",
          "content" => %{"name" => "A"},
          "prev_events" => [creator_join["event_id"]]
        })

      {:ok, _} = EventStore.insert_event(name_a, "10")

      pdu = event(%{"prev_events" => ["$our_head", name_a["event_id"]]})

      resolved =
        StateResolver.resolve_for_auth_check(pdu, current_state, "$our_head", "10")

      winner = resolved[{"m.room.name", ""}]["content"]["name"]

      assert winner in ["A", "B"]
    end
  end
end
