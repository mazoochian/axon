defmodule AxonWeb.ServerNotices do
  @moduledoc """
  Synapse-style server notices: a reserved system account
  (`@server-notices:<server_name>`) that an admin can use to push a message
  into a dedicated, auto-created room with any local user — e.g. "your
  account will be deactivated", "this server is shutting down for
  maintenance". Lazily provisions both the system account and, per
  recipient, a `trusted_private_chat` room (created once and reused for
  every subsequent notice to that user, tracked in `server_notice_rooms`),
  tagged `m.server_notice` in the recipient's room account data so a real
  client can render it distinctly from an ordinary DM.
  """

  import Ecto.Query, only: [from: 2]

  alias AxonCore.{Repo, UserStore}
  alias AxonRoom.{CreateRoom, RoomProcess}

  @system_localpart "server-notices"

  def system_user_id do
    server_name = Application.fetch_env!(:axon_web, :server_name)
    "@#{@system_localpart}:#{server_name}"
  end

  @doc "Sends `content` (a full m.room.message-shaped map) to `user_id`'s server notices room, creating it if needed. Returns {:ok, event_id} or {:error, reason}."
  def send_notice(user_id, content) do
    with :ok <- ensure_local_user(user_id),
         :ok <- ensure_system_user(),
         {:ok, room_id} <- ensure_room(user_id) do
      RoomProcess.send_event(room_id, system_user_id(), "m.room.message", content, state_key: nil)
    end
  end

  defp ensure_local_user(user_id) do
    if Repo.exists?(from(u in "users", where: u.user_id == ^user_id)),
      do: :ok,
      else: {:error, :not_found}
  end

  defp ensure_system_user do
    if Repo.exists?(from(u in "users", where: u.user_id == ^system_user_id())) do
      :ok
    else
      server_name = Application.fetch_env!(:axon_web, :server_name)

      case UserStore.register(@system_localpart, nil,
             server_name: server_name,
             display_name: "Server Notices"
           ) do
        {:ok, _} -> :ok
        # Lost a race with another concurrent notice provisioning the same account — fine.
        {:error, :user_in_use} -> :ok
        error -> error
      end
    end
  end

  defp ensure_room(user_id) do
    case Repo.one(
           from(r in "server_notice_rooms", where: r.user_id == ^user_id, select: r.room_id)
         ) do
      nil -> create_room(user_id)
      room_id -> {:ok, room_id}
    end
  end

  defp create_room(user_id) do
    server_name = Application.fetch_env!(:axon_web, :server_name)

    with {:ok, room_id} <-
           CreateRoom.execute(system_user_id(),
             server_name: server_name,
             preset: "trusted_private_chat",
             name: "Server Notices",
             invite: [user_id],
             # Not meaningful to federate — the recipient is always local
             # (send_notice/2 has already checked that), and this avoids
             # ever trying to gossip a system account's room to anyone else.
             creation_content: %{"m.federate" => false}
           ) do
      # Auto-accept the invite on the recipient's behalf: an invited-only
      # user can't see timeline content (just stripped invite_state), which
      # would defeat the purpose of a notice they're not guaranteed to
      # notice/act on. This is the one place in the codebase a membership
      # event's sender is set to someone other than the actual caller —
      # legitimate here because the room was just created specifically to
      # deliver this message to exactly this user, not general-purpose
      # force-join.
      {:ok, _} =
        RoomProcess.send_event(room_id, user_id, "m.room.member", %{"membership" => "join"},
          state_key: user_id
        )

      Repo.insert_all("server_notice_rooms", [
        %{user_id: user_id, room_id: room_id, inserted_at: DateTime.utc_now(:microsecond)}
      ])

      tag_room(user_id, room_id)
      {:ok, room_id}
    end
  end

  # Server-set room account data on the recipient's behalf — legitimate
  # here specifically because this module IS the server acting on its own
  # authority (unlike AccountDataController.put_room/2, which must reject
  # a client trying to set another user's account data).
  defp tag_room(user_id, room_id) do
    Repo.insert_all(
      "room_account_data",
      [
        %{
          user_id: user_id,
          room_id: room_id,
          type: "m.tag",
          content: %{"tags" => %{"m.server_notice" => %{}}}
        }
      ],
      on_conflict: {:replace, [:content]},
      conflict_target: [:user_id, :room_id, :type]
    )
  end
end
