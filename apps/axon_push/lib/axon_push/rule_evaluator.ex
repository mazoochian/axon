defmodule AxonPush.RuleEvaluator do
  @moduledoc """
  Evaluates Matrix push rules against a room event.

  Rules are evaluated in priority order: override → content → room → sender → underride.
  Returns {:notify, actions} for the first matching enabled rule, or :dont_notify.
  """

  import Ecto.Query
  alias AxonCore.Repo

  @rule_kinds ~w(override content room sender underride)

  @doc """
  Evaluate push rules for `user_id` against `event` in `room_id`.
  `rules` is the default ruleset map (with string keys matching push rule kinds).
  Returns {:notify, actions} | :dont_notify.
  """
  def should_notify?(event, room_id, user_id, rules) do
    # Merge user overrides from DB (not yet persisted — use defaults for now)
    member_count = get_member_count(room_id)
    display_name = get_display_name(user_id)

    Enum.reduce_while(@rule_kinds, :dont_notify, fn kind, _acc ->
      kind_rules = rules[kind] || []
      case eval_kind(kind, kind_rules, event, room_id, user_id, display_name, member_count) do
        {:match, actions} ->
          if "notify" in actions do
            {:halt, {:notify, actions}}
          else
            {:halt, :dont_notify}
          end
        :no_match -> {:cont, :dont_notify}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Kind-level evaluation
  # ---------------------------------------------------------------------------

  # Content rules: single pattern matching against content.body
  defp eval_kind("content", rules, event, _room_id, user_id, _dn, _count) do
    content = event["content"] || %{}
    body = content["body"] || ""
    localpart = localpart(user_id)

    Enum.reduce_while(rules, :no_match, fn rule, _ ->
      if rule["enabled"] != false do
        pattern = rule["pattern"] || ""
        pattern = String.replace(pattern, "${user_localpart}", localpart)
        if glob_match?(pattern, body) do
          {:halt, {:match, rule["actions"] || []}}
        else
          {:cont, :no_match}
        end
      else
        {:cont, :no_match}
      end
    end)
  end

  defp eval_kind(_kind, rules, event, room_id, user_id, display_name, member_count) do
    Enum.reduce_while(rules, :no_match, fn rule, _ ->
      if rule["enabled"] != false do
        conditions = rule["conditions"] || []
        if all_conditions_match?(conditions, event, room_id, user_id, display_name, member_count) do
          {:halt, {:match, rule["actions"] || []}}
        else
          {:cont, :no_match}
        end
      else
        {:cont, :no_match}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Condition evaluation
  # ---------------------------------------------------------------------------

  defp all_conditions_match?(conditions, event, room_id, user_id, display_name, member_count) do
    Enum.all?(conditions, fn cond ->
      eval_condition(cond, event, room_id, user_id, display_name, member_count)
    end)
  end

  defp eval_condition(%{"kind" => "event_match", "key" => key, "pattern" => pattern}, event, _room_id, user_id, _dn, _count) do
    localpart = localpart(user_id)
    pattern = pattern
      |> String.replace("${user_id}", user_id)
      |> String.replace("${user_localpart}", localpart)
    value = get_event_field(event, key)
    glob_match?(pattern, to_string(value || ""))
  end

  defp eval_condition(%{"kind" => "contains_display_name"}, event, _room_id, _user_id, display_name, _count) do
    body = get_in(event, ["content", "body"]) || ""
    display_name != nil and display_name != "" and
      String.contains?(String.downcase(body), String.downcase(display_name))
  end

  defp eval_condition(%{"kind" => "room_member_count", "is" => expr}, _event, _room_id, _user_id, _dn, member_count) do
    eval_count_expr(expr, member_count)
  end

  defp eval_condition(%{"kind" => "event_property_is", "key" => key, "value" => value}, event, _, _, _, _) do
    get_event_field(event, key) == value
  end

  defp eval_condition(%{"kind" => "event_property_contains", "key" => key, "value" => value}, event, _, _, _, _) do
    case get_event_field(event, key) do
      list when is_list(list) -> value in list
      _ -> false
    end
  end

  # sender_notification_permission and unknown conditions default to false (safe)
  defp eval_condition(_cond, _event, _room_id, _user_id, _dn, _count), do: false

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp get_event_field(event, key) do
    # Support dot-separated paths: "content.msgtype", "content.body", "type", "state_key"
    key
    |> String.split(".")
    |> Enum.reduce(event, fn part, acc ->
      if is_map(acc), do: Map.get(acc, part), else: nil
    end)
  end

  # Glob pattern matching: * → any sequence, ? → any single char
  defp glob_match?(pattern, string) do
    regex_str =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    case Regex.compile("^#{regex_str}$", "i") do
      {:ok, re} -> Regex.match?(re, string)
      _ -> false
    end
  end

  defp eval_count_expr(expr, count) do
    cond do
      String.starts_with?(expr, "==") ->
        String.slice(expr, 2..-1//1) |> String.trim() |> Integer.parse() |> case do
          {n, _} -> count == n
          _ -> false
        end
      String.starts_with?(expr, ">=") ->
        String.slice(expr, 2..-1//1) |> String.trim() |> Integer.parse() |> case do
          {n, _} -> count >= n
          _ -> false
        end
      String.starts_with?(expr, "<=") ->
        String.slice(expr, 2..-1//1) |> String.trim() |> Integer.parse() |> case do
          {n, _} -> count <= n
          _ -> false
        end
      String.starts_with?(expr, ">") ->
        String.slice(expr, 1..-1//1) |> String.trim() |> Integer.parse() |> case do
          {n, _} -> count > n
          _ -> false
        end
      String.starts_with?(expr, "<") ->
        String.slice(expr, 1..-1//1) |> String.trim() |> Integer.parse() |> case do
          {n, _} -> count < n
          _ -> false
        end
      true -> false
    end
  end

  defp get_member_count(room_id) do
    Repo.one(
      from m in "room_memberships",
        where: m.room_id == ^room_id and m.membership == "join",
        select: count(m.user_id)
    ) || 0
  end

  defp get_display_name(user_id) do
    Repo.one(
      from p in "user_profiles",
        where: p.user_id == ^user_id,
        select: p.displayname
    )
  end

  defp localpart(user_id) do
    user_id
    |> String.trim_leading("@")
    |> String.split(":")
    |> hd()
  end
end
