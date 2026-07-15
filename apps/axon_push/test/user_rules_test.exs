defmodule AxonPush.UserRulesTest do
  @moduledoc """
  Direct unit tests for `AxonPush.UserRules` — the merge of server defaults
  with per-user overrides/custom rules, previously untested despite backing
  both `GET /pushrules` and `AxonPush.RuleEvaluator`'s actual notification
  decisions.
  """

  use AxonPush.DataCase, async: false

  alias AxonPush.UserRules

  @user "@rules_user:localhost"

  describe "default_rule_id?/2" do
    test "true for a known server-default rule id in its kind" do
      assert UserRules.default_rule_id?("override", ".m.rule.master")
    end

    test "false for a rule id that isn't a default in that kind" do
      refute UserRules.default_rule_id?("override", ".m.rule.does_not_exist")
    end

    test "false when checked against the wrong kind" do
      refute UserRules.default_rule_id?("content", ".m.rule.master")
    end
  end

  describe "effective_rules/1" do
    test "with no stored customization, returns exactly the server defaults" do
      rules = UserRules.effective_rules(@user)
      assert rules["override"] |> Enum.map(& &1["rule_id"]) |> Enum.member?(".m.rule.master")
      assert rules["room"] == []
      assert rules["sender"] == []
    end

    test "a custom rule appears ahead of the kind's defaults" do
      :ok =
        UserRules.put_custom_rule(@user, "content", "my_custom", %{
          "pattern" => "urgent",
          "actions" => ["notify"]
        })

      rules = UserRules.effective_rules(@user)
      [first | _] = rules["content"]

      assert first["rule_id"] == "my_custom"
      assert first["default"] == false
    end

    test "overriding a default rule's enabled state doesn't turn it into a custom rule" do
      :ok = UserRules.put_enabled(@user, "override", ".m.rule.master", true)

      rules = UserRules.effective_rules(@user)
      master = Enum.find(rules["override"], &(&1["rule_id"] == ".m.rule.master"))

      assert master["enabled"] == true
      # pattern/conditions are still the fixed default shape, not attacker/user-controlled
      assert master["conditions"] == []
    end

    test "overriding a default rule's actions replaces just the actions" do
      :ok = UserRules.put_actions(@user, "content", ".m.rule.contains_user_name", ["dont_notify"])

      rules = UserRules.effective_rules(@user)
      rule = Enum.find(rules["content"], &(&1["rule_id"] == ".m.rule.contains_user_name"))

      assert rule["actions"] == ["dont_notify"]
      # pattern is untouched by the actions-only override
      assert rule["pattern"] == "${user_localpart}"
    end
  end

  describe "get_rule/3" do
    test "returns the effective rule for an existing id" do
      rule = UserRules.get_rule(@user, "override", ".m.rule.master")
      assert rule["rule_id"] == ".m.rule.master"
    end

    test "returns nil for a rule id that doesn't exist" do
      assert UserRules.get_rule(@user, "override", ".m.rule.nope") == nil
    end
  end

  describe "put_custom_rule/4" do
    test "creates a genuine custom rule" do
      assert :ok =
               UserRules.put_custom_rule(@user, "room", "!someroom:localhost", %{
                 "actions" => ["notify"]
               })

      rule = UserRules.get_rule(@user, "room", "!someroom:localhost")
      assert rule["enabled"] == true
      assert rule["actions"] == ["notify"]
    end

    test "rejects writing to a server-default rule id" do
      assert UserRules.put_custom_rule(@user, "override", ".m.rule.master", %{"actions" => []}) ==
               {:error, :cannot_replace_default_rule}
    end

    test "replaces an existing custom rule of the same id (upsert)" do
      :ok =
        UserRules.put_custom_rule(@user, "sender", "@bob:localhost", %{"actions" => ["notify"]})

      :ok =
        UserRules.put_custom_rule(@user, "sender", "@bob:localhost", %{
          "actions" => ["dont_notify"]
        })

      rule = UserRules.get_rule(@user, "sender", "@bob:localhost")
      assert rule["actions"] == ["dont_notify"]
    end
  end

  describe "put_enabled/4" do
    test "toggling a default rule for the first time still produces a fully-formed row" do
      :ok = UserRules.put_enabled(@user, "underride", ".m.rule.call", false)

      rule = UserRules.get_rule(@user, "underride", ".m.rule.call")
      assert rule["enabled"] == false
    end

    test "toggling a custom rule's enabled state preserves its other fields" do
      :ok =
        UserRules.put_custom_rule(@user, "content", "custom1", %{
          "pattern" => "hi",
          "actions" => ["notify"]
        })

      :ok = UserRules.put_enabled(@user, "content", "custom1", false)

      rule = UserRules.get_rule(@user, "content", "custom1")
      assert rule["enabled"] == false
      assert rule["pattern"] == "hi"
      assert rule["actions"] == ["notify"]
    end
  end

  describe "put_actions/4" do
    test "setting actions on a not-yet-customized default rule seeds a sane row" do
      :ok = UserRules.put_actions(@user, "override", ".m.rule.tombstone", ["dont_notify"])

      rule = UserRules.get_rule(@user, "override", ".m.rule.tombstone")
      assert rule["actions"] == ["dont_notify"]
      assert rule["enabled"] == true
    end
  end

  describe "delete_rule/3" do
    test "deleting a custom rule removes it entirely" do
      :ok =
        UserRules.put_custom_rule(@user, "sender", "@carl:localhost", %{"actions" => ["notify"]})

      assert UserRules.get_rule(@user, "sender", "@carl:localhost")

      :ok = UserRules.delete_rule(@user, "sender", "@carl:localhost")
      refute UserRules.get_rule(@user, "sender", "@carl:localhost")
    end

    test "deleting an override on a default rule simply reverts it to the true default" do
      :ok = UserRules.put_enabled(@user, "override", ".m.rule.master", true)
      assert UserRules.get_rule(@user, "override", ".m.rule.master")["enabled"] == true

      :ok = UserRules.delete_rule(@user, "override", ".m.rule.master")
      assert UserRules.get_rule(@user, "override", ".m.rule.master")["enabled"] == false
    end

    test "deleting a rule that was never stored is a no-op" do
      assert UserRules.delete_rule(@user, "override", ".m.rule.does_not_exist") == :ok
    end
  end
end
