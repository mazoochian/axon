defmodule AxonWeb.RoomController do
  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, Repo}
  alias AxonRoom.{CreateRoom, RoomProcess}

  # POST /_matrix/client/v3/createRoom
  def create(conn, params) do
    user_id = conn.assigns.current_user_id
    server_name = Application.fetch_env!(:axon_web, :server_name)

    # Validate room_version type — must be string if present
    if Map.has_key?(params, "room_version") and not is_binary(params["room_version"]) do
      conn
      |> put_status(400)
      |> json(%{"errcode" => "M_BAD_JSON", "error" => "room_version must be a string"})
    else
      opts = [
        server_name: server_name,
        name: params["name"],
        topic: params["topic"],
        preset: params["preset"],
        is_direct: params["is_direct"],
        invite: params["invite"] || [],
        room_alias_name: params["room_alias_name"],
        version: params["room_version"],
        creation_content: params["creation_content"],
        initial_state: params["initial_state"] || [],
        visibility: params["visibility"]
      ]

      with {:ok, room_id} <- CreateRoom.execute(user_id, opts) do
        json(conn, %{"room_id" => room_id})
      end
    end
  end

  # GET /_matrix/client/v3/joined_rooms
  def joined_rooms(conn, _params) do
    user_id = conn.assigns.current_user_id
    rooms = EventStore.get_joined_rooms(user_id)
    json(conn, %{"joined_rooms" => rooms})
  end

  # POST /_matrix/client/v3/join/:room_id_or_alias
  # POST /_matrix/client/v3/rooms/:room_id/join
  def join(conn, %{"room_id" => room_id_or_alias} = params) do
    user_id = conn.assigns.current_user_id
    local_server = Application.get_env(:axon_web, :server_name, "localhost")
    server_params = params["server_name"] || []

    # Resolve alias to room_id (local lookup first, then federation)
    {room_id, hint_servers} = resolve_room(room_id_or_alias, local_server, server_params)

    if is_nil(room_id) do
      conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Room not found"})
    else
      room_server = room_id |> String.split(":") |> List.last()
      is_local_room = room_server == local_server or EventStore.room_exists?(room_id)

      if is_local_room do
        # Local room join
        content = %{"membership" => "join"}

        with {:ok, _} <- EventStore.get_room(room_id),
             {:ok, _event_id} <-
               RoomProcess.send_event(room_id, user_id, "m.room.member", content,
                 state_key: user_id
               ) do
          json(conn, %{"room_id" => room_id})
        end
      else
        # Remote room — use federation join flow
        via_servers = if hint_servers != [], do: hint_servers, else: [room_server]

        case AxonFederation.RoomJoin.join_via_federation(room_id, user_id, via_servers) do
          {:ok, _} ->
            json(conn, %{"room_id" => room_id})

          {:error, reason} ->
            conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Could not join room: #{inspect(reason)}"})
        end
      end
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/leave
  def leave(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.current_user_id

    with {:ok, _event_id} <-
           RoomProcess.send_event(room_id, user_id, "m.room.member", %{"membership" => "leave"},
             state_key: user_id
           ) do
      json(conn, %{})
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/forget
  def forget(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.current_user_id

    row =
      Repo.one(
        from m in "room_memberships",
          where: m.room_id == ^room_id and m.user_id == ^user_id,
          select: %{membership: m.membership}
      )

    cond do
      row != nil and row.membership in ["join", "invite"] ->
        conn |> put_status(400) |> json(%{"errcode" => "M_UNKNOWN", "error" => "You must leave the room first"})

      row == nil ->
        json(conn, %{})

      true ->
        # Mark as forgotten (don't delete — we need the leave event in incremental sync)
        Repo.update_all(
          from(m in "room_memberships",
            where: m.room_id == ^room_id and m.user_id == ^user_id),
          set: [forgotten: true]
        )
        json(conn, %{})
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/invite
  def invite(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id
    invitee = params["user_id"]

    unless invitee do
      conn |> put_status(400) |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "user_id required"})
    else
      with {:ok, _event_id} <-
             RoomProcess.send_event(room_id, user_id, "m.room.member", %{"membership" => "invite"},
               state_key: invitee
             ) do
        json(conn, %{})
      end
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/kick
  def kick(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id
    target = params["user_id"]
    reason = params["reason"]

    content = %{"membership" => "leave"}
    content = if reason, do: Map.put(content, "reason", reason), else: content

    with {:ok, _event_id} <-
           RoomProcess.send_event(room_id, user_id, "m.room.member", content,
             state_key: target
           ) do
      json(conn, %{})
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/ban
  def ban(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id
    target = params["user_id"]
    reason = params["reason"]

    content = %{"membership" => "ban"}
    content = if reason, do: Map.put(content, "reason", reason), else: content

    with {:ok, _event_id} <-
           RoomProcess.send_event(room_id, user_id, "m.room.member", content,
             state_key: target
           ) do
      json(conn, %{})
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/unban
  def unban(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id
    target = params["user_id"]

    with {:ok, _event_id} <-
           RoomProcess.send_event(room_id, user_id, "m.room.member", %{"membership" => "leave"},
             state_key: target
           ) do
      json(conn, %{})
    end
  end

  # GET /_matrix/client/v3/rooms/:room_id/members
  def members(conn, %{"room_id" => room_id} = params) do
    memberships = params["membership"]
    filter_memberships = if memberships, do: [memberships], else: ["join", "invite", "ban", "leave"]

    members = EventStore.get_room_members(room_id, filter_memberships)

    chunk =
      Enum.map(members, fn m ->
        %{
          "content" => %{"membership" => m.membership},
          "membership" => m.membership,
          "room_id" => m.room_id,
          "sender" => m.sender,
          "state_key" => m.user_id,
          "type" => "m.room.member"
        }
      end)

    json(conn, %{"chunk" => chunk})
  end

  # GET /_matrix/client/v3/rooms/:room_id/joined_members
  def joined_members(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.current_user_id

    membership =
      Repo.one(from m in "room_memberships",
        where: m.room_id == ^room_id and m.user_id == ^user_id,
        select: m.membership)

    if membership != "join" do
      conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})
    else
      members = EventStore.get_room_members(room_id, ["join"])

      joined =
        Enum.into(members, %{}, fn m ->
          {m.user_id, %{"display_name" => m.display_name, "avatar_url" => m.avatar_url}}
        end)

      json(conn, %{"joined" => joined})
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Returns {room_id, hint_servers} or {nil, []}
  defp resolve_room(room_id_or_alias, local_server, server_params) do
    cond do
      String.starts_with?(room_id_or_alias, "#") ->
        # Alias — try local first
        local_id = Repo.one(from a in "room_aliases", where: a.alias == ^room_id_or_alias, select: a.room_id)

        if local_id do
          {local_id, []}
        else
          # Try federation alias lookup
          alias_server = room_id_or_alias |> String.split(":") |> List.last()
          via = if server_params != [], do: server_params, else: [alias_server]
          resolve_remote_alias(room_id_or_alias, via, local_server)
        end

      String.starts_with?(room_id_or_alias, "!") ->
        {room_id_or_alias, List.wrap(server_params)}

      true ->
        {nil, []}
    end
  end

  defp resolve_remote_alias(room_alias, via_servers, _local_server) do
    Enum.find_value(via_servers, {nil, []}, fn server ->
      case AxonFederation.HttpClient.get(server, "/_matrix/federation/v1/query/directory?room_alias=#{URI.encode(room_alias)}") do
        {:ok, %{"room_id" => room_id, "servers" => servers}} ->
          {room_id, servers}

        _ ->
          false
      end
    end)
  end
end
