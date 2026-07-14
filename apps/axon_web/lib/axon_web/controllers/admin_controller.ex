defmodule AxonWeb.AdminController do
  @moduledoc """
  Server admin API (`/_synapse/admin/v1/...`, mirroring the naming
  convention the existing Synapse-compatible registration bootstrap already
  uses). Every action here is gated by `AxonWeb.Plug.RequireAdmin` — only
  reachable by a user with `users.admin == true`.
  """

  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, Repo, UserStore}

  @default_limit 100
  @max_limit 1000

  defp paging(params) do
    from_ = String.to_integer(params["from"] || "0")
    limit = min(String.to_integer(params["limit"] || "#{@default_limit}"), @max_limit)
    {from_, limit}
  end

  # ---------------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------------

  # GET /_synapse/admin/v1/users?from=&limit=&guests=&deactivated=
  def list_users(conn, params) do
    {from_, limit} = paging(params)

    query =
      from(u in "users",
        order_by: [asc: u.user_id],
        select: %{
          name: u.user_id,
          is_guest: u.is_guest,
          admin: u.admin,
          deactivated: u.deactivated,
          shadow_banned: u.shadow_banned
        }
      )

    query =
      case params["guests"] do
        "false" -> from(u in query, where: u.is_guest == false)
        "true" -> from(u in query, where: u.is_guest == true)
        _ -> query
      end

    query =
      case params["deactivated"] do
        "false" -> from(u in query, where: u.deactivated == false)
        "true" -> from(u in query, where: u.deactivated == true)
        _ -> query
      end

    total = Repo.aggregate(query, :count)
    users = query |> Ecto.Query.offset(^from_) |> Ecto.Query.limit(^limit) |> Repo.all()

    next_token = if from_ + length(users) < total, do: from_ + length(users)

    json(conn, %{"users" => users, "total" => total, "next_token" => next_token})
  end

  # GET /_synapse/admin/v1/users/:user_id
  def get_user(conn, %{"user_id" => user_id}) do
    case Repo.one(
           from(u in "users",
             where: u.user_id == ^user_id,
             select: %{
               name: u.user_id,
               is_guest: u.is_guest,
               admin: u.admin,
               deactivated: u.deactivated,
               shadow_banned: u.shadow_banned
             }
           )
         ) do
      nil -> {:error, :not_found}
      user -> json(conn, user)
    end
  end

  # POST /_synapse/admin/v1/deactivate/:user_id
  def deactivate_user(conn, %{"user_id" => user_id}) do
    with :ok <- ensure_local_user_exists(user_id) do
      UserStore.deactivate(user_id)
      json(conn, %{"id_server_unbind_result" => "success"})
    end
  end

  # POST /_synapse/admin/v1/users/:user_id/shadow_ban
  def shadow_ban(conn, %{"user_id" => user_id}) do
    with :ok <- ensure_local_user_exists(user_id) do
      UserStore.set_shadow_banned(user_id, true)
      json(conn, %{})
    end
  end

  # DELETE /_synapse/admin/v1/users/:user_id/shadow_ban
  def unshadow_ban(conn, %{"user_id" => user_id}) do
    with :ok <- ensure_local_user_exists(user_id) do
      UserStore.set_shadow_banned(user_id, false)
      json(conn, %{})
    end
  end

  defp ensure_local_user_exists(user_id) do
    if Repo.exists?(from(u in "users", where: u.user_id == ^user_id)),
      do: :ok,
      else: {:error, :not_found}
  end

  # ---------------------------------------------------------------------------
  # Rooms
  # ---------------------------------------------------------------------------

  # GET /_synapse/admin/v1/rooms?from=&limit=
  def list_rooms(conn, params) do
    {from_, limit} = paging(params)

    query =
      from(r in "rooms",
        order_by: [asc: r.room_id],
        select: %{
          room_id: r.room_id,
          name: r.canonical_alias,
          creator: r.creator,
          version: r.version,
          is_public: r.is_public,
          blocked: r.blocked
        }
      )

    total = Repo.aggregate(query, :count)
    rooms = query |> Ecto.Query.offset(^from_) |> Ecto.Query.limit(^limit) |> Repo.all()
    next_token = if from_ + length(rooms) < total, do: from_ + length(rooms)

    json(conn, %{"rooms" => rooms, "total_rooms" => total, "next_batch" => next_token})
  end

  # GET /_synapse/admin/v1/rooms/:room_id
  def get_room(conn, %{"room_id" => room_id}) do
    case Repo.one(
           from(r in "rooms",
             where: r.room_id == ^room_id,
             select: %{
               room_id: r.room_id,
               name: r.canonical_alias,
               creator: r.creator,
               version: r.version,
               is_public: r.is_public,
               blocked: r.blocked
             }
           )
         ) do
      nil -> {:error, :not_found}
      room -> json(conn, room)
    end
  end

  # DELETE /_synapse/admin/v1/rooms/:room_id
  #
  # A real moderation action: deletes the room's events, state, and
  # memberships from local storage, and marks it blocked so it can't be
  # recreated under the same id (rejoins are rejected with a clear error
  # rather than silently doing nothing) — matching Synapse's "purge +
  # block" admin room deletion.
  def purge_room(conn, %{"room_id" => room_id}) do
    if Repo.exists?(from(r in "rooms", where: r.room_id == ^room_id)) do
      # Stop the live process first (if resident) so it can't serve stale
      # in-memory state after the DB rows it was built from are gone.
      AxonRoom.RoomProcess.stop_if_running(room_id)
      EventStore.purge_room(room_id)
      json(conn, %{"delete_id" => room_id, "status" => "complete"})
    else
      {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Media
  # ---------------------------------------------------------------------------

  # POST /_synapse/admin/v1/media/quarantine/:server_name/:media_id
  def quarantine_media(conn, %{"media_id" => media_id}) do
    {n, _} =
      Repo.update_all(from(m in "media", where: m.media_id == ^media_id),
        set: [quarantined: true]
      )

    if n > 0, do: json(conn, %{}), else: {:error, :not_found}
  end

  # DELETE /_synapse/admin/v1/media/quarantine/:server_name/:media_id
  def unquarantine_media(conn, %{"media_id" => media_id}) do
    {n, _} =
      Repo.update_all(from(m in "media", where: m.media_id == ^media_id),
        set: [quarantined: false]
      )

    if n > 0, do: json(conn, %{}), else: {:error, :not_found}
  end

  # ---------------------------------------------------------------------------
  # Reports
  # ---------------------------------------------------------------------------

  # GET /_synapse/admin/v1/event_reports?from=&limit=
  def list_reports(conn, params) do
    {from_, limit} = paging(params)

    query =
      from(r in "reports",
        order_by: [desc: r.id],
        select: %{
          id: r.id,
          room_id: r.room_id,
          event_id: r.event_id,
          reporter_id: r.reporter_id,
          reason: r.reason,
          score: r.score,
          received_ts: r.inserted_at
        }
      )

    total = Repo.aggregate(query, :count)
    reports = query |> Ecto.Query.offset(^from_) |> Ecto.Query.limit(^limit) |> Repo.all()
    next_token = if from_ + length(reports) < total, do: from_ + length(reports)

    json(conn, %{"event_reports" => reports, "total" => total, "next_token" => next_token})
  end

  # ---------------------------------------------------------------------------
  # Server notices
  # ---------------------------------------------------------------------------

  # POST /_synapse/admin/v1/send_server_notice
  def send_server_notice(conn, %{"user_id" => user_id, "content" => content}) do
    with {:ok, event_id} <- AxonWeb.ServerNotices.send_notice(user_id, content) do
      json(conn, %{"event_id" => event_id})
    end
  end

  def send_server_notice(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "user_id and content are required"})
  end
end
