defmodule AxonPush.RuleEvaluator do
  @moduledoc """
  Evaluates Matrix push rules against a room event.

  Rules are evaluated in priority order: override → content → room → sender → underride.
  Returns {:notify, actions} for the first matching enabled rule, or :dont_notify.
  """

  import Ecto.Query
  alias AxonCore.{EventStore, Repo}
  alias AxonPush.DefaultRules

  @legacy_mention_rules ~w(.m.rule.contains_display_name .m.rule.contains_user_name .m.rule.roomnotif)
  @count_expr ~r/\A\s*(==|<=|>=|<|>)?\s*(\d+)\s*\z/

  @doc """
  Evaluate push rules for `user_id` against `event` in `room_id`.
  `rules` is the effective ruleset map (with string keys matching push rule
  kinds) — see `AxonPush.UserRules.effective_rules/1` for how server
  defaults and this user's customization get merged into it.
  Returns {:notify, actions} | :dont_notify.
  """
  def should_notify?(event, room_id, user_id, rules) do
    ctx = %{
      event: event,
      room_id: room_id,
      user_id: user_id,
      has_mentions: is_map(event["content"]) and Map.has_key?(event["content"], "m.mentions")
    }

    DefaultRules.kinds()
    |> Enum.reduce_while(ctx, fn kind, ctx ->
      case first_match(rules[kind] || [], ctx, matcher(kind)) do
        {:match, actions, _ctx} -> {:halt, {:match, actions}}
        {:no_match, ctx} -> {:cont, ctx}
      end
    end)
    |> case do
      {:match, actions} -> if "notify" in actions, do: {:notify, actions}, else: :dont_notify
      _ctx -> :dont_notify
    end
  end

  # ---------------------------------------------------------------------------
  # Kind-level evaluation
  # ---------------------------------------------------------------------------

  defp first_match(rules, ctx, matcher) do
    Enum.reduce_while(rules, {:no_match, ctx}, fn rule, {:no_match, ctx} ->
      if active?(rule, ctx) do
        case matcher.(rule, ctx) do
          {true, ctx} -> {:halt, {:match, List.wrap(rule["actions"]), ctx}}
          {false, ctx} -> {:cont, {:no_match, ctx}}
        end
      else
        {:cont, {:no_match, ctx}}
      end
    end)
  end

  defp active?(%{"enabled" => false}, _ctx), do: false

  defp active?(rule, ctx),
    do: not (ctx.has_mentions and rule["rule_id"] in @legacy_mention_rules)

  defp matcher("content") do
    fn rule, ctx ->
      pattern = rule["pattern"]
      body = body(ctx.event)

      matched =
        is_binary(pattern) and body != nil and
          glob_match?(
            String.replace(pattern, "${user_localpart}", localpart(ctx.user_id)),
            body,
            true
          )

      {matched, ctx}
    end
  end

  # Room/sender rules match implicitly by rule_id == room_id / sender, never by
  # a "conditions" array (an empty one would vacuously match every event).
  defp matcher("room"), do: fn rule, ctx -> {rule["rule_id"] == ctx.room_id, ctx} end
  defp matcher("sender"), do: fn rule, ctx -> {rule["rule_id"] == ctx.event["sender"], ctx} end

  defp matcher(_kind) do
    fn rule, ctx ->
      rule
      |> Map.get("conditions")
      |> List.wrap()
      |> Enum.reduce_while({true, ctx}, fn cond, {true, ctx} ->
        case eval_condition(cond, ctx) do
          {true, ctx} -> {:cont, {true, ctx}}
          {false, ctx} -> {:halt, {false, ctx}}
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Condition evaluation
  # ---------------------------------------------------------------------------

  defp eval_condition(%{"kind" => "event_match", "key" => key, "pattern" => pattern}, ctx)
       when is_binary(key) and is_binary(pattern) do
    pattern =
      pattern
      |> String.replace("${user_id}", ctx.user_id)
      |> String.replace("${user_localpart}", localpart(ctx.user_id))

    matched =
      case get_event_field(ctx.event, key) do
        {:ok, value} when is_binary(value) -> glob_match?(pattern, value, key == "content.body")
        _ -> false
      end

    {matched, ctx}
  end

  defp eval_condition(%{"kind" => "contains_display_name"}, ctx) do
    {display_name, ctx} = fetch(ctx, :display_name)
    body = body(ctx.event)

    matched =
      body != nil and is_binary(display_name) and display_name != "" and
        Regex.match?(word_regex(Regex.escape(display_name)), body)

    {matched, ctx}
  end

  defp eval_condition(%{"kind" => "room_member_count", "is" => expr}, ctx) when is_binary(expr) do
    case Regex.run(@count_expr, expr) do
      [_, op, n] ->
        {count, ctx} = fetch(ctx, :member_count)
        {compare(op, count, String.to_integer(n)), ctx}

      nil ->
        {false, ctx}
    end
  end

  defp eval_condition(%{"kind" => "event_property_is", "key" => key, "value" => value}, ctx)
       when is_binary(key) do
    {get_event_field(ctx.event, key) == {:ok, value}, ctx}
  end

  defp eval_condition(%{"kind" => "event_property_contains", "key" => key, "value" => value}, ctx)
       when is_binary(key) do
    matched =
      case get_event_field(ctx.event, key) do
        {:ok, list} when is_list(list) -> value in list
        _ -> false
      end

    {matched, ctx}
  end

  defp eval_condition(%{"kind" => "sender_notification_permission", "key" => key}, ctx)
       when is_binary(key) do
    {power_levels, ctx} = fetch(ctx, :power_levels)

    {sender_level(power_levels, ctx.event["sender"]) >= notification_level(power_levels, key),
     ctx}
  end

  defp eval_condition(_cond, ctx), do: {false, ctx}

  defp compare(op, count, n) when op in ["", "=="], do: count == n
  defp compare(">=", count, n), do: count >= n
  defp compare("<=", count, n), do: count <= n
  defp compare(">", count, n), do: count > n
  defp compare("<", count, n), do: count < n

  # ---------------------------------------------------------------------------
  # Lazily-loaded, per-call room/user data
  # ---------------------------------------------------------------------------

  defp fetch(ctx, key) do
    case ctx do
      %{^key => value} ->
        {value, ctx}

      _ ->
        value = load(key, ctx)
        {value, Map.put(ctx, key, value)}
    end
  end

  defp load(:member_count, %{room_id: room_id}) do
    Repo.one(
      from(m in "room_memberships",
        where: m.room_id == ^room_id and m.membership == "join",
        select: count(m.user_id)
      )
    ) || 0
  end

  defp load(:display_name, %{user_id: user_id}) do
    Repo.one(from(p in "user_profiles", where: p.user_id == ^user_id, select: p.displayname))
  end

  # Without an m.room.power_levels event the room creator has 100 and everyone
  # else 0; in room v12 the creators outrank any power level.
  defp load(:power_levels, %{room_id: room_id}) do
    create = state_content(room_id, "m.room.create")

    creators =
      case create do
        {sender, %{"room_version" => "12"} = content} ->
          [sender | List.wrap(content["additional_creators"])]

        _ ->
          []
      end

    case {state_content(room_id, "m.room.power_levels"), create} do
      {{_, content}, _} when is_map(content) ->
        %{content: content, creators: creators}

      {_, {sender, content}} ->
        %{content: %{"users" => %{(content["creator"] || sender) => 100}}, creators: creators}

      _ ->
        %{content: %{}, creators: creators}
    end
  end

  defp state_content(room_id, type) do
    case EventStore.get_state_event(room_id, type, "") do
      {:ok, event} ->
        map = EventStore.event_to_map(event)
        {map["sender"], map["content"] || %{}}

      _ ->
        nil
    end
  end

  defp sender_level(%{creators: creators, content: content}, sender) do
    if sender in creators do
      :infinity
    else
      users = if is_map(content["users"]), do: content["users"], else: %{}
      to_level(Map.get(users, sender, content["users_default"]), 0)
    end
  end

  defp notification_level(%{content: content}, key) do
    notifications = if is_map(content["notifications"]), do: content["notifications"], else: %{}
    to_level(notifications[key], 50)
  end

  defp to_level(n, _default) when is_integer(n), do: n

  defp to_level(s, default) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp to_level(_, default), do: default

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Dot-separated path; `\.` is a literal dot and `\\` a literal backslash.
  defp get_event_field(event, key) do
    key
    |> split_key("", [])
    |> Enum.reduce_while({:ok, event}, fn part, {:ok, acc} ->
      case acc do
        %{^part => value} -> {:cont, {:ok, value}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp split_key(<<?\\, c, rest::binary>>, cur, acc) when c in [?., ?\\],
    do: split_key(rest, <<cur::binary, c>>, acc)

  defp split_key(<<?., rest::binary>>, cur, acc), do: split_key(rest, "", [cur | acc])
  defp split_key(<<c, rest::binary>>, cur, acc), do: split_key(rest, <<cur::binary, c>>, acc)
  defp split_key(<<>>, cur, acc), do: Enum.reverse([cur | acc])

  # `*` matches any sequence and `?` any single character, case-insensitively.
  # content.body matches anywhere on word boundaries; every other key must
  # match the whole value.
  defp glob_match?(pattern, value, word_boundary?) do
    cond do
      word_boundary? ->
        Regex.match?(word_regex(glob_to_regex(pattern, ".*?")), value)

      String.contains?(pattern, ["*", "?"]) ->
        Regex.match?(Regex.compile!("\\A" <> glob_to_regex(pattern, ".*") <> "\\z", "ius"), value)

      true ->
        String.downcase(pattern) == String.downcase(value)
    end
  end

  defp glob_to_regex(glob, star) do
    for <<c::utf8 <- glob>>, into: "" do
      case c do
        ?* -> star
        ?? -> "."
        c -> Regex.escape(<<c::utf8>>)
      end
    end
  end

  defp word_regex(inner), do: Regex.compile!("(?:\\A|\\W)" <> inner <> "(?:\\W|\\z)", "ius")

  defp body(%{"content" => %{"body" => body}}) when is_binary(body), do: body
  defp body(_event), do: nil

  defp localpart(user_id) do
    user_id
    |> String.trim_leading("@")
    |> String.split(":")
    |> hd()
  end
end
