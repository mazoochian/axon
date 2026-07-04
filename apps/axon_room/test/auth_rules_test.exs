defmodule AxonRoom.AuthRulesTest do
  @moduledoc """
  Direct, pure-function unit tests for `AxonRoom.AuthRules` — no DB, no
  HTTP. `AuthRules.check/3` is exercised across every room-version-6-12
  membership/power-level/state-event authorization branch.
  """

  use ExUnit.Case, async: true

  alias AxonRoom.AuthRules

  @creator "@creator:localhost"
  @alice "@alice:localhost"
  @bob "@bob:localhost"

  # ---------------------------------------------------------------------------
  # State builders
  # ---------------------------------------------------------------------------

  defp create_event(creator \\ @creator) do
    {{"m.room.create", ""}, %{"type" => "m.room.create", "sender" => creator, "content" => %{"creator" => creator}}}
  end

  defp member_event(user_id, membership, extra_content \\ %{}) do
    {{"m.room.member", user_id},
     %{
       "type" => "m.room.member",
       "sender" => user_id,
       "state_key" => user_id,
       "content" => Map.merge(%{"membership" => membership}, extra_content)
     }}
  end

  defp join_rules_event(rule, extra_content \\ %{}) do
    {{"m.room.join_rules", ""},
     %{"type" => "m.room.join_rules", "content" => Map.merge(%{"join_rule" => rule}, extra_content)}}
  end

  defp power_levels_event(content) do
    {{"m.room.power_levels", ""}, %{"type" => "m.room.power_levels", "content" => content}}
  end

  defp state(entries), do: Map.new(entries)

  defp member_event_to_send(sender, target, membership, extra_content \\ %{}) do
    %{
      "type" => "m.room.member",
      "sender" => sender,
      "state_key" => target,
      "content" => Map.merge(%{"membership" => membership}, extra_content)
    }
  end

  defp message_event(sender, content \\ %{"body" => "hi"}) do
    %{"type" => "m.room.message", "sender" => sender, "content" => content}
  end

  defp state_event(sender, type, content) do
    %{"type" => type, "sender" => sender, "state_key" => "", "content" => content}
  end

  # ---------------------------------------------------------------------------
  # m.room.create
  # ---------------------------------------------------------------------------

  describe "m.room.create" do
    test "allowed as the very first event with no prev_events" do
      event = %{"type" => "m.room.create", "sender" => @creator, "prev_events" => [], "content" => %{}}
      assert AuthRules.check(event, %{}, "11") == :ok
    end

    test "rejected if a create event already exists" do
      event = %{"type" => "m.room.create", "sender" => @creator, "prev_events" => [], "content" => %{}}
      assert AuthRules.check(event, state([create_event()]), "11") == {:error, :room_already_created}
    end

    test "rejected if prev_events is non-empty" do
      event = %{"type" => "m.room.create", "sender" => @creator, "prev_events" => ["$x"], "content" => %{}}
      assert AuthRules.check(event, %{}, "11") == {:error, :create_event_has_prev_events}
    end
  end

  # ---------------------------------------------------------------------------
  # m.room.member — join
  # ---------------------------------------------------------------------------

  describe "join" do
    test "creator can join their own just-created room before join_rules exists" do
      st = state([create_event()])
      event = member_event_to_send(@creator, @creator, "join")
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "a non-creator cannot join an implicit invite-only room without an invite" do
      st = state([create_event()])
      event = member_event_to_send(@alice, @alice, "join")
      assert AuthRules.check(event, st, "11") == {:error, :not_invited}
    end

    test "cannot join on behalf of another user" do
      st = state([create_event(), join_rules_event("public")])
      event = member_event_to_send(@alice, @bob, "join")
      assert AuthRules.check(event, st, "11") == {:error, :cannot_join_for_another}
    end

    test "a banned user cannot join even a public room" do
      st = state([create_event(), join_rules_event("public"), member_event(@alice, "ban")])
      event = member_event_to_send(@alice, @alice, "join")
      assert AuthRules.check(event, st, "11") == {:error, :banned}
    end

    test "already-joined user re-sending join is a no-op ok (join rule irrelevant)" do
      st = state([create_event(), join_rules_event("invite"), member_event(@alice, "join")])
      event = member_event_to_send(@alice, @alice, "join")
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "public join_rule allows anyone to join" do
      st = state([create_event(), join_rules_event("public")])
      event = member_event_to_send(@alice, @alice, "join")
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "invite join_rule requires a prior invite" do
      st = state([create_event(), join_rules_event("invite")])
      event = member_event_to_send(@alice, @alice, "join")
      assert AuthRules.check(event, st, "11") == {:error, :not_invited}

      st_invited = state([create_event(), join_rules_event("invite"), member_event(@alice, "invite")])
      assert AuthRules.check(event, st_invited, "11") == :ok
    end

    test "knock join_rule: only invited or knocking users may join" do
      st = state([create_event(), join_rules_event("knock")])
      event = member_event_to_send(@alice, @alice, "join")
      assert AuthRules.check(event, st, "11") == {:error, :not_invited}

      st_knocked = state([create_event(), join_rules_event("knock"), member_event(@alice, "knock")])
      assert AuthRules.check(event, st_knocked, "11") == :ok
    end

    test "restricted join_rule: allowed when invited or when creator" do
      st = state([create_event(), join_rules_event("restricted"), member_event(@alice, "invite")])
      event = member_event_to_send(@alice, @alice, "join")
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "restricted join_rule: rejected with no invite and no valid authoriser stamp" do
      st = state([create_event(), join_rules_event("restricted")])
      event = member_event_to_send(@alice, @alice, "join")
      assert AuthRules.check(event, st, "11") == {:error, :not_invited}
    end

    test "restricted join_rule: allowed when a joined authoriser with invite power vouches" do
      st =
        state([
          create_event(),
          join_rules_event("restricted"),
          member_event(@creator, "join"),
          power_levels_event(%{"users" => %{@creator => 100}, "invite" => 0})
        ])

      event = member_event_to_send(@alice, @alice, "join", %{"join_authorised_via_users_server" => @creator})
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "restricted join_rule: rejected when the named authoriser lacks invite power" do
      st =
        state([
          create_event(),
          join_rules_event("restricted"),
          member_event(@bob, "join"),
          power_levels_event(%{"invite" => 50})
        ])

      event = member_event_to_send(@alice, @alice, "join", %{"join_authorised_via_users_server" => @bob})
      assert AuthRules.check(event, st, "11") == {:error, :not_invited}
    end

    test "restricted join_rule: rejected when the named authoriser isn't actually joined" do
      st = state([create_event(), join_rules_event("restricted")])
      event = member_event_to_send(@alice, @alice, "join", %{"join_authorised_via_users_server" => @bob})
      assert AuthRules.check(event, st, "11") == {:error, :not_invited}
    end
  end

  # ---------------------------------------------------------------------------
  # m.room.member — invite
  # ---------------------------------------------------------------------------

  describe "invite" do
    setup do
      %{base: state([create_event(), member_event(@creator, "join")])}
    end

    test "a joined user with invite power can invite", %{base: st} do
      event = member_event_to_send(@creator, @alice, "invite")
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "a non-joined sender cannot invite" do
      st = state([create_event()])
      event = member_event_to_send(@alice, @bob, "invite")
      assert AuthRules.check(event, st, "11") == {:error, :not_joined}
    end

    test "cannot invite an already-banned target", %{base: st} do
      st = Map.put(st, {"m.room.member", @alice}, elem(member_event(@alice, "ban"), 1))
      event = member_event_to_send(@creator, @alice, "invite")
      assert AuthRules.check(event, st, "11") == {:error, :target_banned}
    end

    test "cannot invite an already-joined target", %{base: st} do
      st = Map.put(st, {"m.room.member", @alice}, elem(member_event(@alice, "join"), 1))
      event = member_event_to_send(@creator, @alice, "invite")
      assert AuthRules.check(event, st, "11") == {:error, :already_joined}
    end

    test "insufficient power rejects an invite" do
      st =
        state([
          create_event(),
          member_event(@alice, "join"),
          power_levels_event(%{"invite" => 50, "users" => %{@alice => 0}})
        ])

      event = member_event_to_send(@alice, @bob, "invite")
      assert AuthRules.check(event, st, "11") == {:error, :insufficient_power}
    end
  end

  # ---------------------------------------------------------------------------
  # m.room.member — leave (self-leave and kick)
  # ---------------------------------------------------------------------------

  describe "leave" do
    test "a joined user can leave" do
      st = state([create_event(), member_event(@alice, "join")])
      event = member_event_to_send(@alice, @alice, "leave")
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "an invited user can rescind by leaving" do
      st = state([create_event(), member_event(@alice, "invite")])
      event = member_event_to_send(@alice, @alice, "leave")
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "a user with no membership cannot leave" do
      st = state([create_event()])
      event = member_event_to_send(@alice, @alice, "leave")
      assert AuthRules.check(event, st, "11") == {:error, :not_joined}
    end

    test "a joined user with kick power can kick a joined target" do
      st =
        state([
          create_event(),
          member_event(@creator, "join"),
          member_event(@alice, "join"),
          power_levels_event(%{"users" => %{@creator => 100}, "kick" => 50})
        ])

      event = member_event_to_send(@creator, @alice, "leave")
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "kicking requires the sender to outrank the target's power" do
      st =
        state([
          create_event(),
          member_event(@creator, "join"),
          member_event(@alice, "join"),
          power_levels_event(%{"users" => %{@creator => 50, @alice => 50}, "kick" => 50})
        ])

      event = member_event_to_send(@creator, @alice, "leave")
      assert AuthRules.check(event, st, "11") == {:error, :insufficient_power}
    end

    test "cannot kick a target who isn't in the room" do
      st = state([create_event(), member_event(@creator, "join"), power_levels_event(%{"users" => %{@creator => 100}})])
      event = member_event_to_send(@creator, @alice, "leave")
      assert AuthRules.check(event, st, "11") == {:error, :target_not_in_room}
    end

    # Regression: unban is a "leave" targeting a banned user, but banned
    # membership isn't in ["join", "invite"] — without a dedicated branch,
    # the generic :target_not_in_room check above rejects every unban,
    # unconditionally, forever. Unban is gated by ban power specifically
    # (not kick power).
    test "a user with ban power can unban (leave targeting a banned user)" do
      st =
        state([
          create_event(),
          member_event(@creator, "join"),
          member_event(@alice, "ban"),
          power_levels_event(%{"users" => %{@creator => 100}, "ban" => 50})
        ])

      event = member_event_to_send(@creator, @alice, "leave")
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "unban requires ban power, not just kick power" do
      st =
        state([
          create_event(),
          member_event(@creator, "join"),
          member_event(@alice, "ban"),
          power_levels_event(%{"users" => %{@creator => 50}, "ban" => 100, "kick" => 50})
        ])

      event = member_event_to_send(@creator, @alice, "leave")
      assert AuthRules.check(event, st, "11") == {:error, :insufficient_power}
    end
  end

  # ---------------------------------------------------------------------------
  # m.room.member — ban
  # ---------------------------------------------------------------------------

  describe "ban" do
    test "a joined user with ban power can ban" do
      st =
        state([
          create_event(),
          member_event(@creator, "join"),
          member_event(@alice, "join"),
          power_levels_event(%{"users" => %{@creator => 100}, "ban" => 50})
        ])

      event = member_event_to_send(@creator, @alice, "ban")
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "insufficient power rejects a ban" do
      st =
        state([
          create_event(),
          member_event(@creator, "join"),
          member_event(@alice, "join"),
          power_levels_event(%{"users" => %{@creator => 0}, "ban" => 50})
        ])

      event = member_event_to_send(@creator, @alice, "ban")
      assert AuthRules.check(event, st, "11") == {:error, :insufficient_power}
    end

    test "non-joined sender cannot ban" do
      st = state([create_event()])
      event = member_event_to_send(@alice, @bob, "ban")
      assert AuthRules.check(event, st, "11") == {:error, :not_joined}
    end
  end

  # ---------------------------------------------------------------------------
  # m.room.member — knock
  # ---------------------------------------------------------------------------

  describe "knock" do
    test "allowed when join_rule is knock and sender not already in the room" do
      st = state([create_event(), join_rules_event("knock")])
      event = member_event_to_send(@alice, @alice, "knock")
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "allowed for knock_restricted too" do
      st = state([create_event(), join_rules_event("knock_restricted")])
      event = member_event_to_send(@alice, @alice, "knock")
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "rejected when join_rule doesn't allow knocking" do
      st = state([create_event(), join_rules_event("invite")])
      event = member_event_to_send(@alice, @alice, "knock")
      assert AuthRules.check(event, st, "11") == {:error, :knocking_not_allowed}
    end

    test "rejected when already joined/banned/invited" do
      st = state([create_event(), join_rules_event("knock"), member_event(@alice, "join")])
      event = member_event_to_send(@alice, @alice, "knock")
      assert AuthRules.check(event, st, "11") == {:error, :already_in_room}
    end

    test "cannot knock on behalf of another user" do
      st = state([create_event(), join_rules_event("knock")])
      event = member_event_to_send(@alice, @bob, "knock")
      assert AuthRules.check(event, st, "11") == {:error, :cannot_knock_for_another}
    end
  end

  # ---------------------------------------------------------------------------
  # Generic state events (state_default / per-type override)
  # ---------------------------------------------------------------------------

  describe "generic state events" do
    test "sender must be joined" do
      st = state([create_event()])
      event = state_event(@alice, "m.room.name", %{"name" => "hi"})
      assert AuthRules.check(event, st, "11") == {:error, :not_joined}
    end

    test "joined sender with default power (0) cannot send a state_default(50) event" do
      st = state([create_event(), member_event(@alice, "join"), power_levels_event(%{"users" => %{@alice => 0}})])
      event = state_event(@alice, "m.room.name", %{"name" => "hi"})
      assert AuthRules.check(event, st, "11") == {:error, :insufficient_power}
    end

    test "joined sender with sufficient power can send a state event" do
      st = state([create_event(), member_event(@alice, "join"), power_levels_event(%{"users" => %{@alice => 50}})])
      event = state_event(@alice, "m.room.name", %{"name" => "hi"})
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "per-event-type override in power_levels.events is honored" do
      st =
        state([
          create_event(),
          member_event(@alice, "join"),
          power_levels_event(%{"users" => %{@alice => 10}, "events" => %{"m.room.name" => 10}})
        ])

      event = state_event(@alice, "m.room.name", %{"name" => "hi"})
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "creator gets implicit power 100 before any power_levels event exists" do
      st = state([create_event(), member_event(@creator, "join")])
      event = state_event(@creator, "m.room.name", %{"name" => "hi"})
      assert AuthRules.check(event, st, "11") == :ok
    end

    test "an explicit (even empty) power_levels event removes the creator's implicit 100" do
      st = state([create_event(), member_event(@creator, "join"), power_levels_event(%{})])
      event = state_event(@creator, "m.room.name", %{"name" => "hi"})
      assert AuthRules.check(event, st, "11") == {:error, :insufficient_power}
    end
  end

  # ---------------------------------------------------------------------------
  # Message (non-state) events
  # ---------------------------------------------------------------------------

  describe "message events" do
    test "sender must be joined" do
      st = state([create_event()])
      assert AuthRules.check(message_event(@alice), st, "11") == {:error, :not_joined}
    end

    test "joined sender with default power can send a message (events_default 0)" do
      st = state([create_event(), member_event(@alice, "join")])
      assert AuthRules.check(message_event(@alice), st, "11") == :ok
    end

    test "events_default above 0 blocks low-power senders" do
      st =
        state([
          create_event(),
          member_event(@alice, "join"),
          power_levels_event(%{"events_default" => 50, "users" => %{@alice => 0}})
        ])

      assert AuthRules.check(message_event(@alice), st, "11") == {:error, :insufficient_power}
    end
  end

  # ---------------------------------------------------------------------------
  # can_invite?/2
  # ---------------------------------------------------------------------------

  describe "can_invite?/2" do
    test "true when at/above the invite power level (default 0)" do
      st = state([create_event()])
      assert AuthRules.can_invite?(@alice, st) == true
    end

    test "false when below a raised invite power level" do
      st = state([create_event(), power_levels_event(%{"invite" => 50})])
      refute AuthRules.can_invite?(@alice, st)
    end
  end

  # ---------------------------------------------------------------------------
  # KNOWN GAP (not fixed here — see plan's fix-small-flag-big policy): the
  # Matrix spec's m.room.power_levels auth rule (v11 rule 8) requires that no
  # power-level value being changed may exceed the sender's OWN current power
  # level (preventing self-escalation and demoting equals/superiors). This
  # implementation only checks the generic state_default/events power gate —
  # it does not compare the new values against the sender's own level. This
  # test documents that gap; it is a genuine privilege-escalation-shaped
  # finding, flagged in the Feature Spec Artifact rather than silently patched
  # here (fixing it correctly means implementing the full per-key comparison
  # rule, not a one-line change).
  # ---------------------------------------------------------------------------

  describe "m.room.power_levels self-escalation (documented gap, not fixed here)" do
    test "a user with exactly state_default power can grant themselves admin (100)" do
      st =
        state([
          create_event(),
          member_event(@alice, "join"),
          power_levels_event(%{"users" => %{@alice => 50}, "state_default" => 50})
        ])

      event = state_event(@alice, "m.room.power_levels", %{"users" => %{@alice => 100}})
      # Spec-correct behavior would reject this (100 > sender's own level 50).
      # Current implementation allows it.
      assert AuthRules.check(event, st, "11") == :ok
    end
  end
end
