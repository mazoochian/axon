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
      extra_create_content = fetch_create_extras(old_room_id)
      initial_state = copy_initial_state(old_room_id)

      if new_version == "12" do
        execute_v12(
          old_room_id,
          user_id,
          new_version,
          server_name,
          extra_create_content,
          initial_state
        )
      else
        execute_legacy(
          old_room_id,
          user_id,
          new_version,
          server_name,
          extra_create_content,
          initial_state
        )
      end
    end
  end

  defp execute_legacy(
         old_room_id,
         user_id,
         new_version,
         server_name,
         extra_create_content,
         initial_state
       ) do
    new_room_id = CreateRoom.generate_room_id(server_name)

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

  # Room v12's room_id is derived from its own create event (MSC4297), so —
  # unlike every earlier version — it can't be pre-generated and handed to
  # the old room's tombstone up front. Reversed order instead: create the
  # new room first (predecessor carries just the old room_id; there's no
  # tombstone event_id yet to include, which is fine — it's informational,
  # not auth-rule-checked in any room version), then tombstone the old room
  # once the new room_id is known.
  defp execute_v12(
         old_room_id,
         user_id,
         new_version,
         server_name,
         extra_create_content,
         initial_state
       ) do
    creation_content = Map.put(extra_create_content, "predecessor", %{"room_id" => old_room_id})

    # The copied m.room.power_levels almost always lists the old room's
    # creator (a normal pre-v12 room has no other way to grant them power)
    # — but v12 rule 10.4 rejects a power_levels event that lists a
    # creator in `users` at all, since they get implicit infinite power
    # instead. Without stripping this, upgrading any ordinary room to v12
    # would fail immediately after creating it.
    initial_state = strip_creator_from_power_levels(initial_state, user_id)

    with {:ok, new_room_id} <-
           CreateRoom.execute(user_id,
             server_name: server_name,
             version: new_version,
             creation_content: creation_content,
             initial_state: initial_state
           ),
         {:ok, _tombstone_event_id} <-
           RoomProcess.send_event(
             old_room_id,
             user_id,
             "m.room.tombstone",
             %{"body" => "This room has been replaced", "replacement_room" => new_room_id},
             state_key: ""
           ) do
      {:ok, new_room_id}
    end
  end

  defp strip_creator_from_power_levels(initial_state, creator_id) do
    Enum.map(initial_state, fn
      %{"type" => "m.room.power_levels", "content" => content} = ev ->
        users = Map.delete(content["users"] || %{}, creator_id)
        %{ev | "content" => Map.put(content, "users", users)}

      ev ->
        ev
    end)
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
