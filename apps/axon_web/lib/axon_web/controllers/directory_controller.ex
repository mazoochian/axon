defmodule AxonWeb.DirectoryController do
  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  import Ecto.Query
  alias AxonCore.Repo

  # GET/POST /_matrix/client/v3/publicRooms
  def public_rooms(conn, params) do
    limit = String.to_integer(params["limit"] || "20")
    since = params["since"]
    search = get_in(params, ["filter", "generic_search_term"])

    # Base query for public rooms
    q =
      from r in "rooms",
        where: r.is_public == true,
        limit: ^limit,
        order_by: [asc: r.room_id],
        select: r.room_id

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
    state_rows = Repo.all(
      from s in "current_room_state",
        join: e in "events", on: e.event_id == s.event_id,
        where: s.room_id == ^room_id and s.type in ["m.room.name", "m.room.topic", "m.room.canonical_alias", "m.room.history_visibility", "m.room.guest_access"],
        select: %{type: s.type, content: e.content}
    )

    state_map = Enum.into(state_rows, %{}, fn r -> {r.type, r.content} end)

    name = get_in(state_map, ["m.room.name", "name"])
    topic = get_in(state_map, ["m.room.topic", "topic"])
    canonical_alias = get_in(state_map, ["m.room.canonical_alias", "alias"])
    history_visibility = get_in(state_map, ["m.room.history_visibility", "history_visibility"]) || "shared"
    guest_access = get_in(state_map, ["m.room.guest_access", "guest_access"]) || "forbidden"

    # Apply search filter on name and topic
    if search do
      search_lower = String.downcase(search)
      name_match = name && String.contains?(String.downcase(name), search_lower)
      topic_match = topic && String.contains?(String.downcase(topic), search_lower)
      alias_match = canonical_alias && String.contains?(String.downcase(canonical_alias), search_lower)
      id_match = String.contains?(String.downcase(room_id), search_lower)
      if not (name_match || topic_match || alias_match || id_match), do: nil, else: build_entry(room_id, name, topic, canonical_alias, history_visibility, guest_access)
    else
      build_entry(room_id, name, topic, canonical_alias, history_visibility, guest_access)
    end
  end

  defp build_entry(room_id, name, topic, canonical_alias, history_visibility, guest_access) do
    num_joined = Repo.one(
      from m in "room_memberships",
        where: m.room_id == ^room_id and m.membership == "join",
        select: count(m.user_id)
    ) || 0

    entry = %{
      "room_id" => room_id,
      "world_readable" => history_visibility == "world_readable",
      "guest_can_join" => guest_access == "can_join",
      "num_joined_members" => num_joined
    }
    entry = if name, do: Map.put(entry, "name", name), else: entry
    entry = if topic, do: Map.put(entry, "topic", topic), else: entry
    entry = if canonical_alias, do: Map.put(entry, "canonical_alias", canonical_alias), else: entry
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
           from a in "room_aliases",
             where: a.alias == ^room_alias,
             select: a.room_id
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

    Repo.insert_all("room_aliases", [
      %{
        alias: room_alias,
        room_id: room_id,
        creator: user_id,
        inserted_at: DateTime.utc_now(:microsecond),
        updated_at: DateTime.utc_now(:microsecond)
      }
    ], on_conflict: :nothing)

    json(conn, %{})
  end

  def put_alias(conn, _params) do
    conn |> put_status(400) |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "room_id required"})
  end

  # GET /_matrix/client/v3/rooms/:room_id/aliases
  def list_room_aliases(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.current_user_id

    # Check membership: only joined members can list aliases
    membership =
      Repo.one(
        from m in "room_memberships",
          where: m.room_id == ^room_id and m.user_id == ^user_id,
          select: m.membership
      )

    if membership != "join" do
      conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})
    else
      aliases =
        Repo.all(from a in "room_aliases", where: a.room_id == ^room_id, select: a.alias)

      json(conn, %{"aliases" => aliases})
    end
  end

  # DELETE /_matrix/client/v3/directory/room/:room_alias
  def delete_alias(conn, %{"room_alias" => room_alias}) do
    user_id = conn.assigns.current_user_id

    alias_row = Repo.one(
      from a in "room_aliases",
        where: a.alias == ^room_alias,
        select: %{creator: a.creator, room_id: a.room_id}
    )

    case alias_row do
      nil ->
        conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Alias not found"})

      %{creator: creator, room_id: room_id} ->
        # Check if user is the creator OR has power level to manage aliases
        if creator == user_id || can_manage_aliases?(user_id, room_id) do
          Repo.delete_all(from a in "room_aliases", where: a.alias == ^room_alias)

          # If this was the canonical alias, clear it via state event
          maybe_clear_canonical_alias(user_id, room_id, room_alias)

          json(conn, %{})
        else
          conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Insufficient power level"})
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
            |> then(fn m -> if new_alts != [], do: Map.put(m, "alt_aliases", new_alts), else: m end)

          RoomProcess.send_event(room_id, user_id, "m.room.canonical_alias", new_content, state_key: "")
        end

      _ -> :ok
    end
  end

  defp can_manage_aliases?(user_id, room_id) do
    alias AxonCore.EventStore

    state_map = EventStore.get_current_state_map(room_id)
    pl = case state_map[{"m.room.power_levels", ""}] do
      nil -> %{}
      ev -> ev["content"] || %{}
    end

    required = get_in(pl, ["events", "m.room.aliases"]) || Map.get(pl, "state_default", 50)
    user_pl = get_in(pl, ["users", user_id]) || Map.get(pl, "users_default", 0)
    user_pl >= required
  end

  defp server_name, do: Application.fetch_env!(:axon_web, :server_name)
end
