defmodule AxonRoom.RoomUpgrade do
  @moduledoc """
  Room version upgrades (`m.room.tombstone` + `POST /rooms/:roomId/upgrade`).

  Spec: https://spec.matrix.org/latest/client-server-api/#room-upgrades

  Flow: pre-generate the new room_id, tombstone the old room referencing it
  (so the tombstone's event_id can go in the new room's create-event
  predecessor), then create the new room with copied state.
  """

  alias AxonCore.EventStore
  alias AxonRoom.{CreateRoom, RoomProcess}

  @copy_state_types ~w(
    m.room.server_acl m.room.encryption m.room.name m.room.topic m.room.avatar
    m.room.guest_access m.room.history_visibility m.room.join_rules
    m.room.power_levels m.room.canonical_alias
  )

  @doc "Errors with :not_joined unless `user_id` currently has membership=join in `room_id`."
  def ensure_joined(room_id, user_id) do
    case EventStore.get_state_event(room_id, "m.room.member", user_id) do
      {:ok, %{content: %{"membership" => "join"}}} -> :ok
      _ -> {:error, :not_joined}
    end
  end

  @doc "Errors with :insufficient_power_level unless `user_id` may send m.room.tombstone in `room_id`."
  def ensure_can_tombstone(room_id, user_id) do
    pl = fetch_power_levels(room_id)
    required = get_in(pl, ["events", "m.room.tombstone"]) || pl["state_default"] || 50
    power = get_in(pl, ["users", user_id]) || pl["users_default"] || 0

    if power >= required, do: :ok, else: {:error, :insufficient_power_level}
  end

  @doc """
  Performs the upgrade: tombstones `old_room_id` and creates a new room on
  `new_version`, copying over ACLs/encryption/name/topic/avatar/guest_access/
  history_visibility/join_rules/power_levels/canonical_alias.

  Returns `{:ok, new_room_id}` or `{:error, reason}`.

  Note: does not migrate other members into the new room — clients follow
  the tombstone's `replacement_room` themselves, per spec.
  """
  def execute(old_room_id, user_id, new_version, server_name) do
    with :ok <- CreateRoom.check_version_supported(new_version) do
      new_room_id = CreateRoom.generate_room_id(server_name)
      extra_create_content = fetch_create_extras(old_room_id)
      initial_state = copy_initial_state(old_room_id)

      with {:ok, tombstone_event_id} <-
             RoomProcess.send_event(
               old_room_id,
               user_id,
               "m.room.tombstone",
               %{"body" => "This room has been replaced", "replacement_room" => new_room_id},
               state_key: ""
             ) do
        creation_content =
          Map.put(extra_create_content, "predecessor", %{
            "room_id" => old_room_id,
            "event_id" => tombstone_event_id
          })

        CreateRoom.execute(user_id,
          room_id: new_room_id,
          server_name: server_name,
          version: new_version,
          creation_content: creation_content,
          initial_state: initial_state
        )
      end
    end
  end

  defp fetch_power_levels(room_id) do
    case EventStore.get_state_event(room_id, "m.room.power_levels", "") do
      {:ok, event} -> event.content
      {:error, :not_found} -> %{}
    end
  end

  defp fetch_create_extras(room_id) do
    case EventStore.get_state_event(room_id, "m.room.create", "") do
      {:ok, event} -> Map.take(event.content, ["type", "m.federate"])
      {:error, :not_found} -> %{}
    end
  end

  defp copy_initial_state(room_id) do
    @copy_state_types
    |> Enum.map(fn type ->
      case EventStore.get_state_event(room_id, type, "") do
        {:ok, event} -> %{"type" => type, "state_key" => "", "content" => event.content}
        {:error, :not_found} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
