defmodule AxonPush.RuleEvaluatorTest do
  @moduledoc """
  Table-driven tests for `AxonPush.RuleEvaluator.should_notify?/4` against
  the real default rule set, covering the override → content → room →
  sender → underride precedence order.
  """

  use AxonPush.DataCase, async: false

  alias AxonPush.{DefaultRules, RuleEvaluator}

  @room "!room:localhost"
  @me "@me:localhost"
  @rules DefaultRules.rules()

  defp insert_member(room_id, user_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all("users", [%{user_id: user_id, localpart: "u#{System.unique_integer([:positive])}", is_guest: false, deactivated: false, admin: false, inserted_at: now, updated_at: now}], on_conflict: :nothing)
    Repo.insert_all("rooms", [%{room_id: room_id, version: "10", creator: user_id, is_public: false, inserted_at: now, updated_at: now}], on_conflict: :nothing)

    Repo.insert_all(
      "room_memberships",
      [%{room_id: room_id, user_id: user_id, membership: "join", event_id: "$#{System.unique_integer([:positive])}", sender: user_id, inserted_at: now, updated_at: now}],
      on_conflict: {:replace, [:membership]},
      conflict_target: [:room_id, :user_id]
    )
  end

  defp set_display_name(user_id, name) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "user_profiles",
      [%{user_id: user_id, displayname: name, inserted_at: now, updated_at: now}],
      on_conflict: {:replace, [:displayname]},
      conflict_target: [:user_id]
    )
  end

  setup do
    insert_member(@room, @me)
    :ok
  end

  test "m.notice is suppressed by the override rule" do
    event = %{"type" => "m.room.message", "sender" => "@alice:localhost", "content" => %{"msgtype" => "m.notice", "body" => "hi"}}
    assert RuleEvaluator.should_notify?(event, @room, @me, @rules) == :dont_notify
  end

  test "an invite targeting me notifies with a default sound and no highlight" do
    event = %{"type" => "m.room.member", "sender" => "@alice:localhost", "state_key" => @me, "content" => %{"membership" => "invite"}}
    assert {:notify, actions} = RuleEvaluator.should_notify?(event, @room, @me, @rules)
    assert %{"set_tweak" => "sound", "value" => "default"} in actions
    assert %{"set_tweak" => "highlight", "value" => false} in actions
  end

  test "an unrelated membership event does not notify" do
    event = %{"type" => "m.room.member", "sender" => "@alice:localhost", "state_key" => "@bob:localhost", "content" => %{"membership" => "join"}}
    assert RuleEvaluator.should_notify?(event, @room, @me, @rules) == :dont_notify
  end

  test "a message containing my display name notifies with highlight" do
    set_display_name(@me, "MyName")
    event = %{"type" => "m.room.message", "sender" => "@alice:localhost", "content" => %{"msgtype" => "m.text", "body" => "hey MyName how are you"}}
    assert {:notify, actions} = RuleEvaluator.should_notify?(event, @room, @me, @rules)
    assert Enum.any?(actions, &match?(%{"set_tweak" => "highlight"}, &1))
  end

  test "a message containing my localpart matches the content rule" do
    event = %{"type" => "m.room.message", "sender" => "@alice:localhost", "content" => %{"msgtype" => "m.text", "body" => "hey me check this out"}}
    assert {:notify, _actions} = RuleEvaluator.should_notify?(event, @room, @me, @rules)
  end

  test "a plain message with no other matches falls through to the generic message underride rule" do
    event = %{"type" => "m.room.message", "sender" => "@alice:localhost", "content" => %{"msgtype" => "m.text", "body" => "nothing special here"}}
    assert {:notify, actions} = RuleEvaluator.should_notify?(event, @room, @me, @rules)
    assert %{"set_tweak" => "highlight", "value" => false} in actions
  end

  test "a message in a 1:1 room matches room_one_to_one before the generic message rule" do
    insert_member(@room, "@alice:localhost")
    event = %{"type" => "m.room.message", "sender" => "@alice:localhost", "content" => %{"msgtype" => "m.text", "body" => "hey there unrelated text"}}

    assert {:notify, actions} = RuleEvaluator.should_notify?(event, @room, @me, @rules)
    assert %{"set_tweak" => "sound", "value" => "default"} in actions
  end

  test "an m.call.invite notifies with a ring sound via the underride rule" do
    event = %{"type" => "m.call.invite", "sender" => "@alice:localhost", "content" => %{}}
    assert {:notify, actions} = RuleEvaluator.should_notify?(event, @room, @me, @rules)
    assert %{"set_tweak" => "sound", "value" => "ring"} in actions
  end

  test "the disabled master override rule doesn't block matching underride rules" do
    event = %{"type" => "m.call.invite", "sender" => "@alice:localhost", "content" => %{}}
    assert {:notify, _} = RuleEvaluator.should_notify?(event, @room, @me, @rules)
  end

  test "a state event with no matching rule at all does not notify" do
    event = %{"type" => "m.room.topic", "sender" => "@alice:localhost", "state_key" => "", "content" => %{"topic" => "hi"}}
    assert RuleEvaluator.should_notify?(event, @room, @me, @rules) == :dont_notify
  end

  test "a disabled content rule is skipped" do
    disabled_rules = put_in(@rules, ["content"], [%{"rule_id" => ".m.rule.contains_user_name", "enabled" => false, "pattern" => "${user_localpart}", "actions" => ["notify"]}])
    event = %{"type" => "m.room.message", "sender" => "@alice:localhost", "content" => %{"msgtype" => "m.text", "body" => "hey me"}}
    # Falls through past the disabled content rule to underride's generic message rule (still notifies, but that's the underride action shape, not content's).
    assert {:notify, actions} = RuleEvaluator.should_notify?(event, @room, @me, disabled_rules)
    assert %{"set_tweak" => "highlight", "value" => false} in actions
  end
end
