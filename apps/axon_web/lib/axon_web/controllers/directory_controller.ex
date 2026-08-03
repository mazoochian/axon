defmodule AxonWeb.DirectoryController do
  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  import Ecto.Query
  alias AxonCore.Repo

  # GET/POST /_matrix/client/v3/publicRooms
  def public_rooms(conn, params) do
    limit = String.to_integer(params["limit"] || "20")
    since = params["since"]
    search = get_in(params, ["filter", "generic_search_term"])

    # Base query for public rooms
    q =
      from(r in "rooms",
        where: r.is_public == true,
        limit: ^limit,
        order_by: [asc: r.room_id],
        select: r.room_id
      )

    q = if since, do: from(r in q, where: r.room_id > ^since), else: q

    room_ids = Repo.all(q)

    # Build rich chunks with name, topic, alias, member count from state
    chunks =
      Enum.map(room_ids, fn room_id ->
        build_public_room_entry(room_id, search)
      end)
      |> Enum.reject(&is_nil/1)

    next_batch = if length(room_ids) == limit, do: List.last(room_ids), else: nil

    resp = %{
      "chunk" => chunks,
      "total_room_count_estimate" => length(chunks)
    }

    resp = if next_batch, do: Map.put(resp, "next_batch", next_batch), else: resp

    json(conn, resp)
  end

  defp build_public_room_entry(room_id, search) do
    # Get current state for name, topic, canonical_alias from current_room_state
    state_rows =
      Repo.all(
        from(s in "current_room_state",
          join: e in "events",
          on: e.event_id == s.event_id,
          where:
            s.room_id == ^room_id and
              s.type in [
                "m.room.name",
                "m.room.topic",
                "m.room.canonical_alias",
                "m.room.history_visibility",
                "m.room.guest_access",
                "m.room.join_rules",
                "m.room.create"
              ],
          select: %{type: s.type, content: e.content}
        )
      )

    state_map = Enum.into(state_rows, %{}, fn r -> {r.type, r.content} end)

    name = get_in(state_map, ["m.room.name", "name"])
    topic = get_in(state_map, ["m.room.topic", "topic"])
    canonical_alias = get_in(state_map, ["m.room.canonical_alias", "alias"])

    history_visibility =
      get_in(state_map, ["m.room.history_visibility", "history_visibility"]) || "shared"

    guest_access = get_in(state_map, ["m.room.guest_access", "guest_access"]) || "forbidden"

    # PublicRoomsChunk.join_rule: "When not present, the room is assumed to
    # be public" — but Complement's directory test asserts the key is
    # actually present, so default explicitly rather than omitting it.
    join_rule = get_in(state_map, ["m.room.join_rules", "join_rule"]) || "public"

    # PublicRoomsChunk.room_type: "The `type` of room (from m.room.create),
    # if any" — omitted entirely for ordinary (non-space) rooms.
    room_type = get_in(state_map, ["m.room.create", "type"])

    # Apply search filter on name and topic
    if search do
      search_lower = String.downcase(search)
      name_match = name && String.contains?(String.downcase(name), search_lower)
      topic_match = topic && String.contains?(String.downcase(topic), search_lower)

      alias_match =
        canonical_alias && String.contains?(String.downcase(canonical_alias), search_lower)

      id_match = String.contains?(String.downcase(room_id), search_lower)

      if not (name_match || topic_match || alias_match || id_match),
        do: nil,
        else:
          build_entry(
            room_id,
            name,
            topic,
            canonical_alias,
            history_visibility,
            guest_access,
            join_rule,
            room_type
          )
    else
      build_entry(
        room_id,
        name,
        topic,
        canonical_alias,
        history_visibility,
        guest_access,
        join_rule,
        room_type
      )
    end
  end

  defp build_entry(
         room_id,
         name,
         topic,
         canonical_alias,
         history_visibility,
         guest_access,
         join_rule,
         room_type
       ) do
    num_joined =
      Repo.one(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.membership == "join",
          select: count(m.user_id)
        )
      ) || 0

    entry = %{
      "room_id" => room_id,
      "world_readable" => history_visibility == "world_readable",
      "guest_can_join" => guest_access == "can_join",
      "num_joined_members" => num_joined,
      "join_rule" => join_rule
    }

    entry = if name, do: Map.put(entry, "name", name), else: entry
    entry = if topic, do: Map.put(entry, "topic", topic), else: entry

    entry =
      if canonical_alias, do: Map.put(entry, "canonical_alias", canonical_alias), else: entry

    entry = if room_type, do: Map.put(entry, "room_type", room_type), else: entry

    entry
  end

  # PUT /_matrix/client/v3/directory/list/room/:room_id
  def set_room_visibility(conn, %{"room_id" => room_id} = params) do
    visibility = params["visibility"]
    is_public = visibility == "public"

    Repo.update_all(
      from(r in "rooms", where: r.room_id == ^room_id),
      set: [is_public: is_public]
    )

    json(conn, %{})
  end

  # GET /_matrix/client/v3/directory/room/:room_alias
  def get_alias(conn, %{"room_alias" => room_alias}) do
    case Repo.one(
           from(a in "room_aliases",
             where: a.alias == ^room_alias,
             select: a.room_id
           )
         ) do
      nil ->
        {:error, :not_found}

      room_id ->
        json(conn, %{"room_id" => room_id, "servers" => [server_name()]})
    end
  end

  # PUT /_matrix/client/v3/directory/room/:room_alias
  def put_alias(conn, %{"room_alias" => room_alias, "room_id" => room_id}) do
    user_id = conn.assigns.current_user_id

    Repo.insert_all(
      "room_aliases",
      [
        %{
          alias: room_alias,
          room_id: room_id,
          creator: user_id,
          inserted_at: DateTime.utc_now(:microsecond),
          updated_at: DateTime.utc_now(:microsecond)
        }
      ],
      on_conflict: :nothing
    )

    json(conn, %{})
  end

  def put_alias(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "room_id required"})
  end

  # GET /_matrix/client/v3/rooms/:room_id/aliases
  def list_room_aliases(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.current_user_id

    # Check membership: only joined members can list aliases
    membership =
      Repo.one(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.user_id == ^user_id,
          select: m.membership
        )
      )

    if membership != "join" do
      conn
      |> put_status(403)
      |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})
    else
      aliases =
        Repo.all(from(a in "room_aliases", where: a.room_id == ^room_id, select: a.alias))

      json(conn, %{"aliases" => aliases})
    end
  end

  # DELETE /_matrix/client/v3/directory/room/:room_alias
  def delete_alias(conn, %{"room_alias" => room_alias}) do
    user_id = conn.assigns.current_user_id

    alias_row =
      Repo.one(
        from(a in "room_aliases",
          where: a.alias == ^room_alias,
          select: %{creator: a.creator, room_id: a.room_id}
        )
      )

    case alias_row do
      nil ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Alias not found"})

      %{creator: creator, room_id: room_id} ->
        # Check if user is the creator OR has power level to manage aliases
        if creator == user_id || can_manage_aliases?(user_id, room_id) do
          Repo.delete_all(from(a in "room_aliases", where: a.alias == ^room_alias))

          # If this was the canonical alias, clear it via state event
          maybe_clear_canonical_alias(user_id, room_id, room_alias)

          json(conn, %{})
        else
          conn
          |> put_status(403)
          |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Insufficient power level"})
        end
    end
  end

  defp maybe_clear_canonical_alias(user_id, room_id, deleted_alias) do
    alias AxonCore.EventStore
    alias AxonRoom.RoomProcess

    case EventStore.get_state_event(room_id, "m.room.canonical_alias", "") do
      {:ok, event} ->
        current_alias = get_in(event.content, ["alias"])
        current_alts = get_in(event.content, ["alt_aliases"]) || []

        new_alias = if current_alias == deleted_alias, do: nil, else: current_alias
        new_alts = Enum.reject(current_alts, &(&1 == deleted_alias))

        if new_alias != current_alias or new_alts != current_alts do
          new_content =
            %{}
            |> then(fn m -> if new_alias, do: Map.put(m, "alias", new_alias), else: m end)
            |> then(fn m ->
              if new_alts != [], do: Map.put(m, "alt_aliases", new_alts), else: m
            end)

          RoomProcess.send_event(room_id, user_id, "m.room.canonical_alias", new_content,
            state_key: ""
          )
        end

      _ ->
        :ok
    end
  end

  # Delegates to AxonRoom.AuthRules — the single authority every other power
  # check in this codebase goes through — rather than reimplementing
  # power-level arithmetic here. That matters in particular for room v12,
  # where the creator(s) hold implicit infinite power and are never listed
  # in power_levels.users; a hand-rolled `users_default` fallback would
  # wrongly refuse a v12 creator who manages an alias without ever having
  # been granted an explicit power_levels entry.
  defp can_manage_aliases?(user_id, room_id) do
    alias AxonCore.EventStore
    alias AxonRoom.AuthRules

    state_map = EventStore.get_current_state_map(room_id)
    version = room_version(state_map)

    AuthRules.can_send_state?(user_id, "m.room.aliases", state_map, version)
  end

  defp room_version(state_map) do
    case state_map[{"m.room.create", ""}] do
      %{"content" => %{"room_version" => v}} -> v
      _ -> "11"
    end
  end

  defp server_name, do: Application.fetch_env!(:axon_web, :server_name)
end
