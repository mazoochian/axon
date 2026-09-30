defmodule AxonWeb.SpaceController do
  @moduledoc """
  Spaces (stable, room version 11+). `m.space.child`/`m.space.parent` are
  plain state events handled by the generic event machinery already — this
  controller adds the `/hierarchy` traversal endpoint and the MSC3266
  single-room `/room_summary` endpoint.

  Spec: https://spec.matrix.org/latest/client-server-api/#spaces

  ## Traversal semantics

  Per MSC2946, the server only recurses through `m.space.child` links from
  rooms whose `m.room.create` `type` is `m.space` — an ordinary room's child
  links (if it has any) are not followed. Traversal is depth-first
  pre-order (visit a room, then immediately descend into its first child's
  subtree before moving to its next sibling), which is what makes `limit`-
  based pagination page boundaries deterministic and match the reference
  behaviour tested by Complement's `TestClientSpacesSummary/pagination`.

  ## Federation

  A child room that isn't resident on this server is fetched via
  `GET /_matrix/federation/v1/hierarchy/{roomId}` on whichever server the
  `m.space.child` event's `via` list names (first one that answers wins).
  Children that can't be fetched are omitted, like any other inaccessible
  room.
  """

  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  import Ecto.Query

  alias AxonCore.{EventStore, Repo}
  alias AxonWeb.{Params, RoomSummary}

  @default_max_depth 5
  @default_limit 50
  # Safety cap on total rooms visited per hierarchy request, independent of
  # the page `limit` — bounds pathological/wide graphs regardless of
  # pagination (recursion is already guarded by `max_depth` and a visited
  # set, but a very wide graph could still be large).
  @max_total_rooms 1000
  @max_depth 50

  # ---------------------------------------------------------------------------
  # GET /_matrix/client/v1/rooms/:room_id/hierarchy
  # ---------------------------------------------------------------------------

  def hierarchy(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id
    suggested_only = params["suggested_only"] in ["true", true]
    max_depth = Params.int(params["max_depth"], @default_max_depth, 0, @max_depth)
    limit = Params.int(params["limit"], @default_limit, 1, @max_total_rooms)
    offset = decode_offset(params["from"])

    if not (local_room_exists?(room_id) and accessible?(room_id, user_id)) do
      not_found(conn)
    else
      all_rooms = walk_all(room_id, user_id, max_depth, suggested_only)
      page = Enum.slice(all_rooms, offset, limit)

      resp = %{"rooms" => page}

      resp =
        if offset + limit < length(all_rooms) do
          Map.put(resp, "next_batch", encode_offset(offset + limit))
        else
          resp
        end

      json(conn, resp)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /_matrix/client/v1/room_summary/:room_id_or_alias  (MSC3266)
  # ---------------------------------------------------------------------------

  def room_summary(conn, %{"room_id_or_alias" => room_id_or_alias}) do
    user_id = conn.assigns.current_user_id

    case resolve_room_id_or_alias(room_id_or_alias) do
      nil ->
        not_found(conn)

      room_id ->
        if local_room_exists?(room_id) and accessible?(room_id, user_id) do
          summary =
            room_id
            |> build_entry([])
            |> Map.delete("children_state")
            |> Map.put("membership", user_membership(room_id, user_id))

          json(conn, summary)
        else
          not_found(conn)
        end
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found or not accessible"})
  end

  defp resolve_room_id_or_alias("!" <> _ = room_id), do: room_id

  defp resolve_room_id_or_alias("#" <> _ = room_alias) do
    Repo.one(from(a in "room_aliases", where: a.alias == ^room_alias, select: a.room_id))
  end

  defp resolve_room_id_or_alias(_), do: nil

  defp user_membership(room_id, user_id) do
    Repo.one(
      from(m in "room_memberships",
        where: m.room_id == ^room_id and m.user_id == ^user_id,
        select: m.membership
      )
    )
  end

  # ---------------------------------------------------------------------------
  # Pagination token — an opaque (to the client) offset into the fully
  # materialized depth-first traversal. The traversal is deterministic given
  # (room_id, user_id, max_depth, suggested_only), which the spec requires
  # `from` to be reused alongside anyway (same `suggested_only`/`max_depth`).
  # ---------------------------------------------------------------------------

  defp encode_offset(n), do: Base.url_encode64(Integer.to_string(n), padding: false)

  defp decode_offset(nil), do: 0

  defp decode_offset(token) do
    with {:ok, s} <- Base.url_decode64(token, padding: false),
         {n, _} <- Integer.parse(s),
         true <- n >= 0 do
      n
    else
      _ -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Depth-first traversal
  # ---------------------------------------------------------------------------

  defp walk_all(root_room_id, user_id, max_depth, suggested_only) do
    do_walk([{root_room_id, 0, []}], MapSet.new(), [], user_id, max_depth, suggested_only)
    |> Enum.reverse()
  end

  defp do_walk([], _visited, acc, _user_id, _max_depth, _suggested_only), do: acc

  defp do_walk(_stack, _visited, acc, _user_id, _max_depth, _suggested_only)
       when length(acc) >= @max_total_rooms,
       do: acc

  defp do_walk([{room_id, depth, via} | rest], visited, acc, user_id, max_depth, suggested_only) do
    if MapSet.member?(visited, room_id) do
      do_walk(rest, visited, acc, user_id, max_depth, suggested_only)
    else
      visited = MapSet.put(visited, room_id)

      case resolve_entry(room_id, user_id, via, suggested_only) do
        nil ->
          do_walk(rest, visited, acc, user_id, max_depth, suggested_only)

        {entry, children} ->
          next_stack =
            if depth < max_depth and entry["room_type"] == "m.space" do
              child_stack =
                for %{"state_key" => child_id} = c when is_binary(child_id) <- children,
                    do: {child_id, depth + 1, via_servers(c)}

              child_stack ++ rest
            else
              rest
            end

          do_walk(next_stack, visited, [entry | acc], user_id, max_depth, suggested_only)
      end
    end
  end

  defp via_servers(%{"content" => %{"via" => via}}) when is_list(via),
    do: Enum.filter(via, &is_binary/1)

  defp via_servers(_child), do: []

  # Resolves one room's summary + its space-children (stripped state), either
  # from local state or, when the room isn't resident here, via federation.
  # Returns `{entry, children}` or `nil` if the room doesn't exist / isn't
  # accessible / couldn't be fetched.
  defp resolve_entry(room_id, user_id, via, suggested_only) do
    if local_room_exists?(room_id) do
      if accessible?(room_id, user_id) do
        children = child_events(room_id, suggested_only)
        {build_entry(room_id, children), children}
      else
        nil
      end
    else
      fetch_remote_entry(room_id, via, suggested_only)
    end
  end

  defp fetch_remote_entry(_room_id, [], _suggested_only), do: nil

  defp fetch_remote_entry(room_id, via_servers, suggested_only) do
    path =
      "/_matrix/federation/v1/hierarchy/#{URI.encode(room_id)}?suggested_only=#{suggested_only}"

    Enum.find_value(via_servers, fn server ->
      case AxonFederation.HttpClient.get(server, path) do
        {:ok, %{"room" => room}} when is_map(room) ->
          children = room["children_state"]
          {room, if(is_list(children), do: Enum.filter(children, &is_map/1), else: [])}

        _ ->
          nil
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Accessibility
  # ---------------------------------------------------------------------------

  # A room is visible in the hierarchy if the requester is joined/invited,
  # the room is joinable/world-readable without membership, or — for a
  # `restricted`/`knock_restricted` room — the requester is joined to one of
  # the rooms named in the join rule's `allow` list (typically the space
  # this room is being viewed from).
  defp accessible?(room_id, user_id) do
    local_room_exists?(room_id) and
      (is_member?(room_id, user_id) or publicly_visible?(room_id) or
         satisfies_restricted_allow?(room_id, user_id))
  end

  defp local_room_exists?(room_id) do
    Repo.one(from(r in "rooms", where: r.room_id == ^room_id, select: 1)) != nil
  end

  defp is_member?(room_id, user_id) do
    Repo.one(
      from(m in "room_memberships",
        where:
          m.room_id == ^room_id and m.user_id == ^user_id and m.membership in ["join", "invite"],
        select: 1
      )
    ) != nil
  end

  defp publicly_visible?(room_id) do
    state = RoomSummary.current_state(room_id, ["m.room.join_rules", "m.room.history_visibility"])
    join_rule = get_in(state, ["m.room.join_rules", "join_rule"])
    history_visibility = get_in(state, ["m.room.history_visibility", "history_visibility"])
    join_rule in ["public", "knock"] or history_visibility == "world_readable"
  end

  defp satisfies_restricted_allow?(room_id, user_id) do
    state = RoomSummary.current_state(room_id, ["m.room.join_rules"])
    join_rule = get_in(state, ["m.room.join_rules", "join_rule"])

    if join_rule in ["restricted", "knock_restricted"] do
      state |> RoomSummary.allow_room_ids() |> Enum.any?(&EventStore.joined?(&1, user_id))
    else
      false
    end
  end

  defp child_events(room_id, suggested_only) do
    # m.space.child with empty content means "removed" — exclude those.
    rows =
      Repo.all(
        from(s in "current_room_state",
          join: e in "events",
          on: e.event_id == s.event_id,
          where: s.room_id == ^room_id and s.type == "m.space.child",
          # Deterministic, oldest-link-first order. The query is otherwise
          # unordered, so Postgres was free to return these in any order and
          # in practice returned them newest-first — which made children_state
          # non-reproducible between runs. Clients (and Complement's hierarchy
          # matcher) compare children_state as an ordered sequence, so an
          # arbitrary order is both untestable and unhelpful to render.
          order_by: [asc: e.origin_server_ts, asc: s.state_key],
          select: %{
            state_key: s.state_key,
            content: e.content,
            sender: e.sender,
            origin_server_ts: e.origin_server_ts
          }
        )
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
    room_version =
      Repo.one(from(r in "rooms", where: r.room_id == ^room_id, select: r.version)) || "1"

    room_id
    |> RoomSummary.build("invite")
    |> Map.merge(%{"room_version" => room_version, "children_state" => children})
  end
end
