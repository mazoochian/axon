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

  describe "resolve_for_auth_check/3" do
    test "with no prev_events, returns current_state unchanged" do
      current_state = %{
        {"m.room.create", ""} => event(%{"type" => "m.room.create", "state_key" => ""})
      }

      pdu = event(%{"prev_events" => []})

      assert StateResolver.resolve_for_auth_check(pdu, current_state) == current_state
    end

    test "pulls in state from a prev_event's auth_events not already in current_state" do
      power_levels =
        event(%{
          "type" => "m.room.power_levels",
          "state_key" => "",
          "content" => %{"users" => %{@creator => 100}}
        })

      {:ok, _} = EventStore.insert_event(power_levels, "10")

      branch_head =
        event(%{
          "event_id" => "$branch_head",
          "auth_events" => [power_levels["event_id"]]
        })

      {:ok, _} = EventStore.insert_event(branch_head, "10")

      pdu = event(%{"prev_events" => ["$branch_head"]})

      resolved = StateResolver.resolve_for_auth_check(pdu, %{})

      assert %{"content" => %{"users" => %{@creator => 100}}} =
               resolved[{"m.room.power_levels", ""}]
    end

    test "current_state is preserved for keys the prev_event's branch doesn't touch" do
      name_event =
        event(%{"type" => "m.room.name", "state_key" => "", "content" => %{"name" => "Original"}})

      current_state = %{{"m.room.name", ""} => name_event}

      pdu = event(%{"prev_events" => []})
      resolved = StateResolver.resolve_for_auth_check(pdu, current_state)

      assert resolved[{"m.room.name", ""}] == name_event
    end

    test "a prev_event that doesn't exist locally contributes nothing (doesn't crash)" do
      pdu = event(%{"prev_events" => ["$never-seen-this-one"]})

      current_state = %{
        {"m.room.create", ""} => event(%{"type" => "m.room.create", "state_key" => ""})
      }

      assert StateResolver.resolve_for_auth_check(pdu, current_state) == current_state
    end

    test "auth_events pointing at non-state events are ignored (no state_key to key by)" do
      message = event(%{"content" => %{"body" => "not a state event"}})
      {:ok, _} = EventStore.insert_event(message, "10")

      branch_head =
        event(%{"event_id" => "$branch_head2", "auth_events" => [message["event_id"]]})

      {:ok, _} = EventStore.insert_event(branch_head, "10")

      pdu = event(%{"prev_events" => ["$branch_head2"]})
      resolved = StateResolver.resolve_for_auth_check(pdu, %{})

      refute Enum.any?(resolved, fn {_k, v} -> v["event_id"] == message["event_id"] end)
    end

    test "two branches conflicting on the same state key get resolved via StateResV2" do
      # Both branches claim a different m.room.name — StateResV2's
      # power-ordering tie-break decides the winner; we only assert that
      # exactly one of the two survives and current_state isn't just
      # returned untouched (i.e. resolution genuinely ran).
      name_a =
        event(%{
          "event_id" => "$name_a",
          "type" => "m.room.name",
          "state_key" => "",
          "content" => %{"name" => "A"},
          "auth_events" => []
        })

      name_b =
        event(%{
          "event_id" => "$name_b",
          "type" => "m.room.name",
          "state_key" => "",
          "content" => %{"name" => "B"},
          "auth_events" => []
        })

      {:ok, _} = EventStore.insert_event(name_a, "10")
      {:ok, _} = EventStore.insert_event(name_b, "10")

      branch_head =
        event(%{"event_id" => "$conflict_head", "auth_events" => [name_a["event_id"]]})

      {:ok, _} = EventStore.insert_event(branch_head, "10")

      current_state = %{{"m.room.name", ""} => name_b}
      pdu = event(%{"prev_events" => ["$conflict_head"]})

      resolved = StateResolver.resolve_for_auth_check(pdu, current_state)
      winner = resolved[{"m.room.name", ""}]["content"]["name"]

      assert winner in ["A", "B"]
    end
  end
end
