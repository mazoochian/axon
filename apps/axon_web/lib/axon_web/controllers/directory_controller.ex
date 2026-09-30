defmodule AxonWeb.DirectoryController do
  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  import Ecto.Query
  alias AxonCore.{EventStore, Repo}
  alias AxonWeb.RoomSummary

  # GET/POST /_matrix/client/v3/publicRooms
  def public_rooms(conn, params) do
    limit = AxonWeb.Params.int(params["limit"], 20, 1, 500)
    since = if is_binary(params["since"]), do: params["since"]

    search =
      case params["filter"] do
        %{"generic_search_term" => term} when is_binary(term) and term != "" ->
          String.downcase(term)

        _ ->
          nil
      end

    q =
      from(r in "rooms",
        where: r.is_public == true,
        limit: ^limit,
        order_by: [asc: r.room_id],
        select: r.room_id
      )

    q = if since, do: from(r in q, where: r.room_id > ^since), else: q

    room_ids = Repo.all(q)

    # PublicRoomsChunk.join_rule: "When not present, the room is assumed to
    # be public".
    chunks =
      room_ids
      |> Enum.map(&RoomSummary.build(&1, "public"))
      |> Enum.filter(&matches_search?(&1, search))

    resp = %{"chunk" => chunks, "total_room_count_estimate" => length(chunks)}

    resp =
      if length(room_ids) == limit,
        do: Map.put(resp, "next_batch", List.last(room_ids)),
        else: resp

    json(conn, resp)
  end

  defp matches_search?(_entry, nil), do: true

  defp matches_search?(entry, search) do
    Enum.any?(["name", "topic", "canonical_alias", "room_id"], fn key ->
      is_binary(entry[key]) and String.contains?(String.downcase(entry[key]), search)
    end)
  end

  # PUT /_matrix/client/v3/directory/list/room/:room_id
  # Same permission as Synapse's room-list check: a server admin, or a joined
  # member allowed to send m.room.canonical_alias.
  def set_room_visibility(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id

    cond do
      params["visibility"] not in [nil, "public", "private"] ->
        invalid_param(conn, "visibility must be \"public\" or \"private\"")

      not room_exists?(room_id) ->
        {:error, :not_found}

      not (AxonWeb.Plug.RequireAdmin.admin?(user_id) or
               (EventStore.joined?(room_id, user_id) and
                  can_send_state?(user_id, room_id, "m.room.canonical_alias"))) ->
        {:error, :insufficient_power}

      true ->
        Repo.update_all(
          from(r in "rooms", where: r.room_id == ^room_id),
          set: [is_public: params["visibility"] != "private"]
        )

        json(conn, %{})
    end
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
        get_remote_alias(conn, room_alias)

      room_id ->
        json(conn, %{"room_id" => room_id, "servers" => [server_name()]})
    end
  end

  # Not one of our own aliases — for a room_alias suffixed with a server
  # other than ours, ask that server directly (the same federation
  # query/directory lookup RoomController's join flow already uses),
  # rather than only ever answering for aliases we host ourselves.
  #
  # room_alias must go through URI.encode_www_form/1, not URI.encode/1:
  # every Matrix alias starts with "#", which URI.encode/1 leaves
  # unescaped. Finch.build/5 re-parses the whole URL string with
  # URI.parse/1 before sending, and per RFC 3986 an unescaped "#"
  # introduces the fragment — so the literal alias never reached the wire
  # at all, only an empty room_alias= did. Silent 404s on every remote
  # alias lookup; the existing test coverage missed it because
  # FakeRemoteMatrixServer.put_response/3 matches by path regex only and
  # never inspects the query string it actually received.
  defp get_remote_alias(conn, room_alias) do
    alias_server = AxonCore.MatrixId.server_name(room_alias)
    local_server = server_name()

    with true <- is_binary(alias_server) and alias_server != local_server,
         {:ok, %{"room_id" => room_id, "servers" => servers}} <-
           AxonFederation.HttpClient.get(
             alias_server,
             "/_matrix/federation/v1/query/directory?room_alias=#{URI.encode_www_form(room_alias)}"
           ) do
      json(conn, %{"room_id" => room_id, "servers" => servers})
    else
      _ -> {:error, :not_found}
    end
  end

  # PUT /_matrix/client/v3/directory/room/:room_alias
  def put_alias(conn, %{"room_alias" => room_alias, "room_id" => room_id})
      when is_binary(room_id) do
    user_id = conn.assigns.current_user_id

    cond do
      not valid_local_alias?(room_alias) ->
        invalid_param(conn, "Room alias must be of the form #localpart:#{server_name()}")

      not room_exists?(room_id) ->
        {:error, :not_found}

      not (EventStore.joined?(room_id, user_id) or AxonWeb.Plug.RequireAdmin.admin?(user_id)) ->
        {:error, :not_joined}

      true ->
        now = DateTime.utc_now(:microsecond)

        {inserted, _} =
          Repo.insert_all(
            "room_aliases",
            [
              %{
                alias: room_alias,
                room_id: room_id,
                creator: user_id,
                inserted_at: now,
                updated_at: now
              }
            ],
            on_conflict: :nothing
          )

        if inserted == 1 do
          json(conn, %{})
        else
          conn
          |> put_status(409)
          |> json(%{
            "errcode" => "M_UNKNOWN",
            "error" => "Room alias #{room_alias} already exists"
          })
        end
    end
  end

  def put_alias(conn, %{"room_id" => _}), do: invalid_param(conn, "room_id must be a string")

  def put_alias(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "room_id required"})
  end

  defp valid_local_alias?("#" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [localpart, server] -> localpart != "" and server == server_name()
      _ -> false
    end
  end

  defp valid_local_alias?(_), do: false

  defp invalid_param(conn, error) do
    conn |> put_status(400) |> json(%{"errcode" => "M_INVALID_PARAM", "error" => error})
  end

  defp room_exists?(room_id) do
    Repo.exists?(from(r in "rooms", where: r.room_id == ^room_id))
  end

  # GET /_matrix/client/v3/rooms/:room_id/aliases
  def list_room_aliases(conn, %{"room_id" => room_id}) do
    if not EventStore.joined?(room_id, conn.assigns.current_user_id) do
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
  defp can_manage_aliases?(user_id, room_id),
    do: can_send_state?(user_id, room_id, "m.room.aliases")

  defp can_send_state?(user_id, room_id, event_type) do
    state_map = AxonCore.EventStore.get_current_state_map(room_id)
    AxonRoom.AuthRules.can_send_state?(user_id, event_type, state_map, room_version(state_map))
  end

  defp room_version(state_map) do
    case state_map[{"m.room.create", ""}] do
      %{"content" => %{"room_version" => v}} -> v
      _ -> "11"
    end
  end

  defp server_name, do: AxonWeb.ServerName.get()
end
