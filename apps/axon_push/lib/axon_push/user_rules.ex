defmodule AxonPush.UserRules do
  @moduledoc """
  Persistence and merging for per-user push rule customization
  (`PUT`/`DELETE` on `/pushrules/...`, previously silently discarded — see
  `AxonWeb.PushRulesController`).

  A user's rule set for a kind is the server defaults
  (`AxonPush.DefaultRules`) with any stored customization applied:
  server-default rule ids (`.m.rule.*`) can only have their `enabled`/
  `actions` overridden (their `conditions`/`pattern` are fixed); any other
  rule id is a genuine custom rule the user created from scratch, which is
  evaluated before the (possibly-overridden) defaults for that kind.

  Custom-rule order (and hence priority — earlier in a kind's list wins)
  is `inserted_at` order, which `PUT .../{kind}/{ruleId}?before=<rule_id>`
  or `?after=<rule_id>` can override: instead of always stamping "now"
  (append to the end), a positioned insert stamps a synthetic timestamp
  strictly between the target rule and its current neighbor, so it sorts
  into that slot without renumbering any other row. `before`/`after` may
  only reference another *custom* rule of the same kind (not a
  server-default rule id — matches spec, "not possible to add a rule
  relative to a predefined server rule": a default id simply won't be
  found among this kind's custom rows).
  """

  import Ecto.Query
  alias AxonCore.Repo
  alias AxonPush.DefaultRules

  @rule_kinds ~w(override content room sender underride)

  @doc "Whether rule_id names one of this kind's server-default rules."
  def default_rule_id?(kind, rule_id) do
    DefaultRules.rules()
    |> Map.get(kind, [])
    |> Enum.any?(&(&1["rule_id"] == rule_id))
  end

  @doc """
  Full merged 5-kind ruleset for `user_id` — used both for `GET
  /pushrules` responses and by `AxonPush.RuleEvaluator`/`Dispatcher` so
  notification decisions actually reflect what the user configured instead
  of only ever the server defaults.
  """
  def effective_rules(user_id) do
    rows_by_kind =
      Repo.all(
        from(r in "user_push_rules",
          where: r.user_id == ^user_id,
          order_by: [asc: r.inserted_at],
          select: %{
            kind: r.kind,
            rule_id: r.rule_id,
            is_default: r.is_default,
            pattern: r.pattern,
            conditions: r.conditions,
            actions: r.actions,
            enabled: r.enabled
          }
        )
      )
      |> Enum.group_by(& &1.kind)

    Map.new(@rule_kinds, fn kind -> {kind, merge_kind(kind, rows_by_kind[kind] || [])} end)
  end

  defp merge_kind(kind, rows) do
    overrides = rows |> Enum.filter(& &1.is_default) |> Map.new(&{&1.rule_id, &1})
    custom = Enum.reject(rows, & &1.is_default)

    defaults =
      DefaultRules.rules()
      |> Map.get(kind, [])
      |> Enum.map(fn default_rule ->
        case overrides[default_rule["rule_id"]] do
          nil -> default_rule
          override -> apply_override(default_rule, override)
        end
      end)

    Enum.map(custom, &row_to_rule/1) ++ defaults
  end

  defp apply_override(default_rule, override) do
    default_rule
    |> Map.put("enabled", override.enabled)
    |> then(fn r -> if override.actions, do: Map.put(r, "actions", override.actions), else: r end)
  end

  defp row_to_rule(row) do
    %{"rule_id" => row.rule_id, "default" => false, "enabled" => row.enabled}
    |> maybe_put("pattern", row.pattern)
    |> maybe_put("conditions", row.conditions)
    |> maybe_put("actions", row.actions)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "The single effective rule for {kind, rule_id}, or nil if it doesn't exist."
  def get_rule(user_id, kind, rule_id) do
    effective_rules(user_id)
    |> Map.get(kind, [])
    |> Enum.find(&(&1["rule_id"] == rule_id))
  end

  @doc """
  Creates or replaces a custom rule (PUT with a full body). Rejects
  writing to a server-default rule id — those can only have `enabled`/
  `actions` overridden via `put_enabled/4` / `put_actions/4`, matching
  spec (a default rule's own conditions/pattern are fixed).

  `attrs["before"]`/`attrs["after"]` (mutually exclusive), if present,
  must each name another custom rule of the same kind and position this
  rule immediately more/less important than it; omitted, the rule is
  appended as the least important custom rule (existing behavior).
  """
  def put_custom_rule(user_id, kind, rule_id, attrs) do
    if default_rule_id?(kind, rule_id) do
      {:error, :cannot_replace_default_rule}
    else
      with {:ok, inserted_at} <-
             resolve_position(user_id, kind, rule_id, attrs["before"], attrs["after"]) do
        upsert(user_id, kind, rule_id, %{
          is_default: false,
          pattern: attrs["pattern"],
          conditions: attrs["conditions"],
          actions: attrs["actions"] || [],
          enabled: true,
          inserted_at: inserted_at
        })
      end
    end
  end

  @doc "Sets enabled on a rule (default or custom)."
  def put_enabled(user_id, kind, rule_id, enabled) when is_boolean(enabled) do
    is_default = default_rule_id?(kind, rule_id)

    upsert(user_id, kind, rule_id, %{is_default: is_default},
      replace: [:enabled],
      set: %{enabled: enabled}
    )
  end

  @doc "Sets actions on a rule (default or custom)."
  def put_actions(user_id, kind, rule_id, actions) when is_list(actions) do
    is_default = default_rule_id?(kind, rule_id)

    upsert(user_id, kind, rule_id, %{is_default: is_default},
      replace: [:actions],
      set: %{actions: actions}
    )
  end

  @doc "Deletes a stored row — for a default-rule override this simply reverts to the true default."
  def delete_rule(user_id, kind, rule_id) do
    Repo.delete_all(
      from(r in "user_push_rules",
        where: r.user_id == ^user_id and r.kind == ^kind and r.rule_id == ^rule_id
      )
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # No positioning requested: fall through to the default "append" behavior
  # (upsert/2 stamps `now` on insert, leaves it alone on conflict).
  defp resolve_position(_user_id, _kind, _rule_id, before, after_)
       when before in [nil, ""] and after_ in [nil, ""] do
    {:ok, nil}
  end

  defp resolve_position(_user_id, _kind, _rule_id, before, after_)
       when before not in [nil, ""] and after_ not in [nil, ""] do
    {:error, :relative_rule_conflict}
  end

  defp resolve_position(user_id, kind, rule_id, before, after_) do
    neighbors =
      Repo.all(
        from(r in "user_push_rules",
          where:
            r.user_id == ^user_id and r.kind == ^kind and r.is_default == false and
              r.rule_id != ^rule_id,
          order_by: [asc: r.inserted_at],
          select: %{rule_id: r.rule_id, inserted_at: r.inserted_at}
        )
      )
      # Schemaless select decodes the `timestamp` column as NaiveDateTime;
      # normalize to DateTime so this matches the DateTime.utc_now/1 used
      # elsewhere in this module for the same column.
      |> Enum.map(
        &Map.update!(&1, :inserted_at, fn ndt -> DateTime.from_naive!(ndt, "Etc/UTC") end)
      )

    target = before || after_

    case Enum.find_index(neighbors, &(&1.rule_id == target)) do
      nil ->
        {:error, :relative_rule_not_found}

      idx ->
        {lower, upper} =
          if before do
            {at(neighbors, idx - 1), Enum.at(neighbors, idx).inserted_at}
          else
            {Enum.at(neighbors, idx).inserted_at, at(neighbors, idx + 1)}
          end

        {:ok, midpoint(lower, upper)}
    end
  end

  defp at(list, idx) when idx >= 0 and idx < length(list), do: Enum.at(list, idx).inserted_at
  defp at(_list, _idx), do: nil

  defp midpoint(nil, upper), do: DateTime.add(upper, -1000, :microsecond)
  defp midpoint(lower, nil), do: DateTime.add(lower, 1000, :microsecond)

  defp midpoint(lower, upper) do
    mid_us = div(DateTime.to_unix(lower, :microsecond) + DateTime.to_unix(upper, :microsecond), 2)
    DateTime.from_unix!(mid_us, :microsecond)
  end

  # `inserted_at` in base_attrs (set only by a positioned put_custom_rule/4
  # call) is both the value used on insert and, unusually, replaced on
  # conflict too — repositioning an *existing* custom rule must actually
  # move it, unlike every other conflict path here which leaves the
  # original creation order alone.
  defp upsert(user_id, kind, rule_id, base_attrs) do
    {explicit_inserted_at, base_attrs} = Map.pop(base_attrs, :inserted_at)

    row =
      Map.merge(
        %{
          user_id: user_id,
          kind: kind,
          rule_id: rule_id,
          inserted_at: explicit_inserted_at || DateTime.utc_now(:microsecond)
        },
        base_attrs
      )

    replace_cols = [:is_default, :pattern, :conditions, :actions, :enabled]
    replace_cols = if explicit_inserted_at, do: [:inserted_at | replace_cols], else: replace_cols

    Repo.insert_all("user_push_rules", [row],
      on_conflict: {:replace, replace_cols},
      conflict_target: [:user_id, :kind, :rule_id]
    )

    :ok
  end

  # For enabled/actions-only updates against a row that may not exist yet
  # (e.g. toggling a default rule's enabled state for the first time): seed
  # sane values for any column not being set, then apply the requested
  # column on top, so a subsequent read has a fully-formed row either way.
  defp upsert(user_id, kind, rule_id, base_attrs, replace: replace_cols, set: set_attrs) do
    existing =
      Repo.one(
        from(r in "user_push_rules",
          where: r.user_id == ^user_id and r.kind == ^kind and r.rule_id == ^rule_id,
          select: %{
            pattern: r.pattern,
            conditions: r.conditions,
            actions: r.actions,
            enabled: r.enabled
          }
        )
      ) || %{pattern: nil, conditions: nil, actions: nil, enabled: true}

    row =
      %{
        user_id: user_id,
        kind: kind,
        rule_id: rule_id,
        inserted_at: DateTime.utc_now(:microsecond)
      }
      |> Map.merge(base_attrs)
      |> Map.merge(existing)
      |> Map.merge(set_attrs)

    Repo.insert_all("user_push_rules", [row],
      on_conflict: {:replace, replace_cols},
      conflict_target: [:user_id, :kind, :rule_id]
    )

    :ok
  end
end
