defmodule AxonWeb.AccountDataController do
  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  import Ecto.Query
  alias AxonCore.Repo

  # GET /_matrix/client/v3/user/:user_id/account_data/:type
  @doc """
  Returns the account data for the given user and type. In the Matrix spec, there are several account data types:
  - `m.push_rules` — the user's notification push rule set
  - `m.direct` — map of user_id → list of DM room_ids (powers the "Direct Messages" section in clients)
  - `m.secret_storage.key.<key_id>` — an SSSS key descriptor
  - `m.secret_storage.default_key` — pointer to which SSSS key is the default
  - `m.cross_signing.master` / `m.cross_signing.self_signing` / `m.cross_signing.user_signing` — the client's **encrypted private** cross-signing keys, stashed here so they sync to other devices (distinct from the *public* halves stored in `cross_signing_keys` via `/keys/device_signing/upload`, which we covered earlier)
  - `m.megolm_backup.v1` — pointer/config for the key backup
  """
  def get(conn, %{"user_id" => user_id, "type" => type}) do
    requester = conn.assigns.current_user_id

    if user_id != requester do
      {:error, :forbidden}
    else
      case Repo.one(
             from(a in "account_data",
               where: a.user_id == ^user_id and a.type == ^type,
               select: a.content
             )
           ) do
        nil -> {:error, :not_found}
        content -> json(conn, content)
      end
    end
  end

  # PUT /_matrix/client/v3/user/:user_id/account_data/:type
  @doc """
  Updates user's account data (user ID and type)
  """
  def put(conn, %{"user_id" => user_id, "type" => type} = params) do
    requester = conn.assigns.current_user_id

    if user_id != requester do
      {:error, :forbidden}
    else
      content = Map.drop(params, ~w(user_id type))

      Repo.insert_all(
        "account_data",
        [
          %{
            user_id: user_id,
            type: type,
            content: content
          }
        ],
        on_conflict: {:replace, [:content]},
        conflict_target: [:user_id, :type]
      )

      Repo.insert_all("account_data_stream", [%{user_id: user_id, type: type}])

      json(conn, %{})
    end
  end

  # GET /_matrix/client/v3/user/:user_id/rooms/:room_id/account_data/:type
  @doc """
  Fetches user's custom room state. There are various types of items here:
  - `m.tag` — the classic example. Lets a client mark a room as favourite/low-priority for organizing the room list, e.g. `{"tags": {"m.favourite": {"order": 0.5}}}`. This is exactly why the per-user scoping matters: your "favourite rooms" list is personal, not shared with everyone else in the room.
  - `m.fully_read` — historically used for read-marker position tracking per room per user (now largely superseded by the `/read_markers` and `/receipt` endpoints, but the account-data version still exists in the spec for compatibility).
  - Client-specific extensions — e.g. some clients stash per-room UI state (widget layouts, custom notification overrides for that specific room) under their own namespaced `type` like `io.element.something`.
  """
  def get_room(conn, %{"user_id" => user_id, "room_id" => room_id, "type" => type}) do
    requester = conn.assigns.current_user_id

    if user_id != requester do
      {:error, :forbidden}
    else
      case Repo.one(
             from(a in "room_account_data",
               where: a.user_id == ^user_id and a.room_id == ^room_id and a.type == ^type,
               select: a.content
             )
           ) do
        nil -> {:error, :not_found}
        content -> json(conn, content)
      end
    end
  end

  # PUT /_matrix/client/v3/user/:user_id/rooms/:room_id/account_data/:type
  @doc """
  Update user's local room account data
  """
  def put_room(conn, %{"user_id" => user_id, "room_id" => room_id, "type" => type} = params) do
    requester = conn.assigns.current_user_id

    if user_id != requester do
      {:error, :forbidden}
    else
      content = Map.drop(params, ~w(user_id room_id type))

      Repo.insert_all(
        "room_account_data",
        [
          %{
            user_id: user_id,
            room_id: room_id,
            type: type,
            content: content
          }
        ],
        on_conflict: {:replace, [:content]},
        conflict_target: [:user_id, :room_id, :type]
      )

      json(conn, %{})
    end
  end
end
