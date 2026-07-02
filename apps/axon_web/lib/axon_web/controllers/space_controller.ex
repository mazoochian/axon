defmodule AxonWeb.SpaceController do
  @moduledoc """
  Spaces (stable, room version 11+). `m.space.child`/`m.space.parent` are
  plain state events handled by the generic event machinery already — this
  controller only adds the `/hierarchy` traversal endpoint.

  Spec: https://spec.matrix.org/latest/client-server-api/#spaces
  """

  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  import Ecto.Query

  alias AxonCore.Repo

  @default_max_depth 5
  @default_limit 50

  # GET /_matrix/client/v1/rooms/:room_id/hierarchy
  def hierarchy(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id
    suggested_only = params["suggested_only"] in ["true", true]
    max_depth = parse_int(params["max_depth"], @default_max_depth)
    limit = parse_int(params["limit"], @default_limit)

    if not accessible?(room_id, user_id) do
      conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found or not accessible"})
    else
      rooms = walk(room_id, user_id, max_depth, limit, suggested_only)
      json(conn, %{"rooms" => rooms})
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end
  defp parse_int(v, _default) when is_integer(v), do: v

  defp walk(root_room_id, user_id, max_depth, limit, suggested_only) do
    walk([{root_room_id, 0}], MapSet.new(), [], user_id, max_depth, limit, suggested_only)
  end

  defp walk([], _visited, acc, _user_id, _max_depth, _limit, _suggested_only), do: Enum.reverse(acc)

  defp walk(_queue, _visited, acc, _user_id, _max_depth, limit, _suggested_only) when length(acc) >= limit,
    do: Enum.reverse(acc)

  defp walk([{room_id, depth} | rest], visited, acc, user_id, max_depth, limit, suggested_only) do
    cond do
      MapSet.member?(visited, room_id) ->
        walk(rest, visited, acc, user_id, max_depth, limit, suggested_only)

      not accessible?(room_id, user_id) ->
        walk(rest, visited, acc, user_id, max_depth, limit, suggested_only)

      true ->
        visited = MapSet.put(visited, room_id)
        children = child_events(room_id, suggested_only)
        entry = build_entry(room_id, children)

        next_queue =
          if depth < max_depth do
            child_ids = Enum.map(children, & &1["state_key"])
            rest ++ Enum.map(child_ids, &{&1, depth + 1})
          else
            rest
          end

        walk(next_queue, visited, [entry | acc], user_id, max_depth, limit, suggested_only)
    end
  end

  # A room is visible in the hierarchy if the requester is joined/invited, or
  # the room is joinable/world-readable without membership.
  defp accessible?(room_id, user_id) do
    room_exists = Repo.one(from(r in "rooms", where: r.room_id == ^room_id, select: 1)) != nil

    room_exists and
      (is_member?(room_id, user_id) or publicly_visible?(room_id))
  end

  defp is_member?(room_id, user_id) do
    Repo.one(
      from m in "room_memberships",
        where: m.room_id == ^room_id and m.user_id == ^user_id and m.membership in ["join", "invite"],
        select: 1
    ) != nil
  end

  defp publicly_visible?(room_id) do
    state = current_state_map(room_id, ["m.room.join_rules", "m.room.history_visibility"])
    join_rule = get_in(state, ["m.room.join_rules", "join_rule"])
    history_visibility = get_in(state, ["m.room.history_visibility", "history_visibility"])
    join_rule in ["public", "knock"] or history_visibility == "world_readable"
  end

  defp current_state_map(room_id, types) do
    Repo.all(
      from s in "current_room_state",
        join: e in "events", on: e.event_id == s.event_id,
        where: s.room_id == ^room_id and s.type in ^types,
        select: %{type: s.type, content: e.content}
    )
    |> Enum.into(%{}, fn r -> {r.type, r.content} end)
  end

  defp child_events(room_id, suggested_only) do
    # m.space.child with empty content means "removed" — exclude those.
    rows =
      Repo.all(
        from s in "current_room_state",
          join: e in "events", on: e.event_id == s.event_id,
          where: s.room_id == ^room_id and s.type == "m.space.child",
          select: %{state_key: s.state_key, content: e.content, sender: e.sender, origin_server_ts: e.origin_server_ts}
      )
      |> Enum.reject(&(&1.content == %{} or &1.content == nil))

    rows =
      if suggested_only,
        do: Enum.filter(rows, &(get_in(&1.content, ["suggested"]) == true)),
        else: rows

    Enum.map(rows, fn r ->
      %{
        "type" => "m.space.child",
        "state_key" => r.state_key,
        "content" => r.content,
        "sender" => r.sender,
        "origin_server_ts" => r.origin_server_ts
      }
    end)
  end

  defp build_entry(room_id, children) do
    state =
      current_state_map(room_id, [
        "m.room.name",
        "m.room.topic",
        "m.room.avatar",
        "m.room.canonical_alias",
        "m.room.history_visibility",
        "m.room.guest_access",
        "m.room.join_rules",
        "m.room.create"
      ])

    num_joined =
      Repo.one(
        from m in "room_memberships",
          where: m.room_id == ^room_id and m.membership == "join",
          select: count(m.user_id)
      ) || 0

    room_type = get_in(state, ["m.room.create", "type"])
    guest_access = get_in(state, ["m.room.guest_access", "guest_access"]) || "forbidden"
    history_visibility = get_in(state, ["m.room.history_visibility", "history_visibility"]) || "shared"
    join_rule = get_in(state, ["m.room.join_rules", "join_rule"]) || "invite"

    entry = %{
      "room_id" => room_id,
      "num_joined_members" => num_joined,
      "world_readable" => history_visibility == "world_readable",
      "guest_can_join" => guest_access == "can_join",
      "join_rule" => join_rule,
      "children_state" => children
    }

    entry
    |> put_if(get_in(state, ["m.room.name", "name"]), "name")
    |> put_if(get_in(state, ["m.room.topic", "topic"]), "topic")
    |> put_if(get_in(state, ["m.room.avatar", "url"]), "avatar_url")
    |> put_if(get_in(state, ["m.room.canonical_alias", "alias"]), "canonical_alias")
    |> put_if(room_type, "room_type")
  end

  defp put_if(map, nil, _key), do: map
  defp put_if(map, value, key), do: Map.put(map, key, value)
end
