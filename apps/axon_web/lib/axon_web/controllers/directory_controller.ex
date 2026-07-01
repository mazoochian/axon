defmodule AxonWeb.DirectoryController do
  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  import Ecto.Query
  alias AxonCore.Repo

  # GET /_matrix/client/v3/publicRooms
  def public_rooms(conn, params) do
    limit = String.to_integer(params["limit"] || "20")
    since = params["since"]
    search = get_in(params, ["filter", "generic_search_term"])

    q =
      from r in "rooms",
        where: r.is_public == true,
        limit: ^limit,
        order_by: [asc: r.room_id],
        select: %{room_id: r.room_id}

    q =
      if search do
        from r in q, where: ilike(r.room_id, ^"%#{search}%")
      else
        q
      end

    q =
      if since != nil do
        from r in q, where: r.room_id > ^since
      else
        q
      end

    rooms = Repo.all(q)

    chunks = Enum.map(rooms, fn r ->
      %{"room_id" => r.room_id, "world_readable" => false, "guest_can_join" => false}
    end)

    next_batch = if length(rooms) == limit, do: List.last(rooms).room_id, else: nil

    resp = %{
      "chunk" => chunks,
      "total_room_count_estimate" => length(chunks)
    }
    resp = if next_batch, do: Map.put(resp, "next_batch", next_batch), else: resp

    json(conn, resp)
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
