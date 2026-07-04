defmodule AxonPush.DefaultRulesTest do
  @moduledoc "Structural checks on the built-in default push rule set."

  use ExUnit.Case, async: true

  alias AxonPush.DefaultRules

  @expected_kinds ~w(override content room sender underride)
  @expected_override_ids ~w(.m.rule.master .m.rule.suppress_notices .m.rule.invite_for_me
                             .m.rule.member_event .m.rule.contains_display_name
                             .m.rule.tombstone .m.rule.roomnotif)
  @expected_content_ids ~w(.m.rule.contains_user_name)
  @expected_underride_ids ~w(.m.rule.call .m.rule.encrypted_room_one_to_one
                              .m.rule.room_one_to_one .m.rule.message .m.rule.encrypted)

  test "has all five rule kinds" do
    assert Map.keys(DefaultRules.rules()) |> Enum.sort() == Enum.sort(@expected_kinds)
  end

  test "override rules include every spec-required default override rule" do
    ids = DefaultRules.rules()["override"] |> Enum.map(& &1["rule_id"])
    for id <- @expected_override_ids, do: assert(id in ids)
  end

  test "content rules include the display-username rule" do
    ids = DefaultRules.rules()["content"] |> Enum.map(& &1["rule_id"])
    assert @expected_content_ids -- ids == []
  end

  test "underride rules include every spec-required default underride rule" do
    ids = DefaultRules.rules()["underride"] |> Enum.map(& &1["rule_id"])
    for id <- @expected_underride_ids, do: assert(id in ids)
  end

  test "every rule has default: true, an :enabled boolean, and a non-empty rule_id" do
    for {_kind, rules} <- DefaultRules.rules(), rule <- rules do
      assert rule["default"] == true
      assert is_boolean(rule["enabled"])
      assert is_binary(rule["rule_id"]) and rule["rule_id"] != ""
    end
  end

  test "the master rule is disabled by default (per spec, it exists but doesn't suppress everything)" do
    master = Enum.find(DefaultRules.rules()["override"], &(&1["rule_id"] == ".m.rule.master"))
    assert master["enabled"] == false
  end
end
