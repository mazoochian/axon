defmodule AxonSync.PresenceTest do
  @moduledoc """
  Tests `AxonSync.Presence` (ETS-backed, started by `AxonSync.Application`)
  — set/get round trip, activity bumping, versioned change tracking, and
  the tick-driven idle/offline transitions (time-travelled via direct ETS
  manipulation + a forced `:tick` message rather than waiting real minutes).
  """

  use ExUnit.Case, async: false

  alias AxonSync.Presence

  @table :axon_presence

  defp uid(prefix), do: "@#{prefix}_#{System.unique_integer([:positive])}:localhost"

  test "set_presence then get round-trips presence and status_msg" do
    user = uid("alice")
    :ok = Presence.set_presence(user, "online", "at the keyboard")

    result = Presence.get(user)
    assert result["presence"] == "online"
    assert result["status_msg"] == "at the keyboard"
    assert result["currently_active"] == true
  end

  test "get for a never-seen user returns the offline default" do
    assert Presence.get(uid("neverseen")) == %{
             "presence" => "offline",
             "currently_active" => false
           }
  end

  test "bump_activity brings an offline user online, preserving no status_msg" do
    user = uid("bob")
    :ok = Presence.set_presence(user, "offline")
    Presence.bump_activity(user)
    # bump_activity is a cast; give it a moment to land.
    :sys.get_state(AxonSync.Presence)

    assert Presence.get(user)["presence"] == "online"
  end

  test "bump_activity on an already-online user preserves presence and status_msg" do
    user = uid("carol")
    :ok = Presence.set_presence(user, "unavailable", "away")
    Presence.bump_activity(user)
    :sys.get_state(AxonSync.Presence)

    result = Presence.get(user)
    assert result["presence"] == "unavailable"
    assert result["status_msg"] == "away"
  end

  test "current_version increases monotonically with each record" do
    v1 = Presence.current_version()
    Presence.set_presence(uid("x"), "online")
    v2 = Presence.current_version()
    assert v2 > v1
  end

  test "changes_since returns only entries after the given version, for requested users only" do
    alice = uid("alice_changes")
    bob = uid("bob_changes")
    charlie = uid("charlie_changes")

    Presence.set_presence(alice, "online")
    baseline = Presence.current_version()

    Presence.set_presence(bob, "online")
    Presence.set_presence(charlie, "online")

    changes = Presence.changes_since([alice, bob, charlie], baseline)
    refute Map.has_key?(changes, alice)
    assert Map.has_key?(changes, bob)
    assert Map.has_key?(changes, charlie)
  end

  test "changes_since dedupes to each user's latest state" do
    user = uid("flapper")
    baseline = Presence.current_version()

    Presence.set_presence(user, "online")
    Presence.set_presence(user, "unavailable")
    Presence.set_presence(user, "online", "final state")

    changes = Presence.changes_since([user], baseline)
    assert changes[user]["presence"] == "online"
    assert changes[user]["status_msg"] == "final state"
  end

  test "bump_activity for a completely unseen user brings them online with no status_msg" do
    user = uid("neverbumped")
    Presence.bump_activity(user)
    :sys.get_state(AxonSync.Presence)

    result = Presence.get(user)
    assert result["presence"] == "online"
    refute Map.has_key?(result, "status_msg")
  end

  describe "set_remote/4 (inbound federation m.presence EDU)" do
    test "records the remote user's reported presence and derives last_active_ts from last_active_ago" do
      user = uid("remoteuser")
      :ok = Presence.set_remote(user, "unavailable", "remote status", 5_000)

      result = Presence.get(user)
      assert result["presence"] == "unavailable"
      assert result["status_msg"] == "remote status"
      assert result["last_active_ago"] >= 5_000
    end

    test "a non-integer last_active_ago falls back to now" do
      user = uid("remoteuser2")
      :ok = Presence.set_remote(user, "online", nil, nil)

      result = Presence.get(user)
      assert result["presence"] == "online"
      assert result["last_active_ago"] < 1_000
    end

    test "set_remote does not re-broadcast to federation:fanout (no rebroadcast loop)" do
      user = uid("remoteuser3")
      Phoenix.PubSub.subscribe(Axon.PubSub, "federation:fanout")

      :ok = Presence.set_remote(user, "online", nil, 0)

      refute_receive {:presence_changed, ^user, _}, 200
      Phoenix.PubSub.unsubscribe(Axon.PubSub, "federation:fanout")
    end
  end

  describe "log trimming (trim_log/0, exercised past @log_max_size)" do
    test "once the change log exceeds the max size, the oldest entry is dropped on the next write" do
      # Use a synthetic negative-version range so these entries always sort
      # before every real (monotonically increasing, non-negative) version
      # written by the rest of the suite, and so they're unambiguous to
      # clean up afterward without touching real data.
      synthetic = for v <- -20_001..-1, do: {v, "@filler:localhost"}
      :ets.insert(:axon_presence_log, synthetic)

      oldest_before = :ets.first(:axon_presence_log)
      assert oldest_before == -20_001

      Presence.set_presence(uid("trimtrigger"), "online")

      oldest_after = :ets.first(:axon_presence_log)
      refute oldest_after == oldest_before

      :ets.select_delete(:axon_presence_log, [{{:"$1", :_}, [{:<, :"$1", 0}], [true]}])
    end
  end

  describe "tick-driven transitions (time-travelled via direct ETS write)" do
    test "an idle online user transitions to unavailable after the idle window" do
      user = uid("idler")
      :ok = Presence.set_presence(user, "online")

      # Force last_active_ts far enough in the past to cross @idle_after (5 min)
      # without waiting for it — same table, same shape the GenServer writes.
      [{^user, presence, status_msg, _ts, version}] = :ets.lookup(@table, user)
      long_ago = System.system_time(:millisecond) - :timer.minutes(10)
      :ets.insert(@table, {user, presence, status_msg, long_ago, version})

      send(AxonSync.Presence, :tick)
      :sys.get_state(AxonSync.Presence)

      assert Presence.get(user)["presence"] == "unavailable"
    end

    test "a very stale user (past the offline window) transitions straight to offline" do
      user = uid("gonedark")
      :ok = Presence.set_presence(user, "online")

      [{^user, presence, status_msg, _ts, version}] = :ets.lookup(@table, user)
      long_ago = System.system_time(:millisecond) - :timer.minutes(45)
      :ets.insert(@table, {user, presence, status_msg, long_ago, version})

      send(AxonSync.Presence, :tick)
      :sys.get_state(AxonSync.Presence)

      assert Presence.get(user)["presence"] == "offline"
    end

    test "a recently-active user is left alone by tick" do
      user = uid("fresh")
      :ok = Presence.set_presence(user, "online")

      send(AxonSync.Presence, :tick)
      :sys.get_state(AxonSync.Presence)

      assert Presence.get(user)["presence"] == "online"
    end
  end
end
