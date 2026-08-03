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

  Options:
    - `:additional_creators` — list of user IDs to set as the new room's
      `additional_creators` (room v12 / MSC4289 only — ignored for any
      other target version). Validated the same way `CreateRoom` validates
      it at room-creation time (array of well-formed user IDs).

  Returns `{:ok, new_room_id}` or `{:error, reason}`.

  Note: does not migrate other members into the new room — clients follow
  the tombstone's `replacement_room` themselves, per spec.
  """
  def execute(old_room_id, user_id, new_version, server_name, opts \\ []) do
    additional_creators = opts[:additional_creators] || []

    with :ok <- CreateRoom.check_version_supported(new_version),
         :ok <- validate_additional_creators(new_version, additional_creators) do
      extra_create_content = fetch_create_extras(old_room_id)
      initial_state = copy_initial_state(old_room_id)

      if new_version == "12" do
        execute_v12(
          old_room_id,
          user_id,
          new_version,
          server_name,
          extra_create_content,
          initial_state,
          additional_creators
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

  # additional_creators is a room v12 (MSC4289) concept — an omitted/empty
  # list is always fine (the common case: no additional creators
  # requested), regardless of target version. A non-empty list only makes
  # sense when upgrading *to* v12 (see TestMSC4289PrivilegedRoomCreators_Upgrades
  # in Complement); everything else is rejected with the same
  # :invalid_additional_creators atom CreateRoom uses (fallback_controller.ex
  # already maps it to 400 M_INVALID_PARAM), rather than silently ignoring a
  # param the client explicitly set.
  defp validate_additional_creators(_version, []), do: :ok

  defp validate_additional_creators("12", list) do
    CreateRoom.check_additional_creators("12", %{"additional_creators" => list})
  end

  defp validate_additional_creators(_version, _list), do: {:error, :invalid_additional_creators}

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
  #
  # The upgrader (`user_id`) always becomes the new room's primary creator
  # (they're the one whose CreateRoom.execute/2 call this is), regardless of
  # who created the old room — the old room's own creator/additional_creators
  # are *not* inherited automatically; only `additional_creators` explicitly
  # passed to this upgrade becomes the new room's additional_creators (see
  # TestMSC4289PrivilegedRoomCreators_Upgrades in Complement, which asserts
  # exactly this for both v11->v12 and v12->v12 upgrades).
  defp execute_v12(
         old_room_id,
         user_id,
         new_version,
         server_name,
         extra_create_content,
         initial_state,
         additional_creators
       ) do
    creation_content =
      extra_create_content
      |> Map.put("predecessor", %{"room_id" => old_room_id})
      |> maybe_put_additional_creators(additional_creators)

    # The copied m.room.power_levels almost always lists the old room's
    # creator (a normal pre-v12 room has no other way to grant them power)
    # — but v12 rule 10.4 rejects a power_levels event that lists a
    # creator (primary or additional) in `users` at all, since they get
    # implicit infinite power instead. Without stripping this, upgrading
    # any ordinary room to v12 (or naming a moderator as an additional
    # creator on upgrade) would fail immediately after creating it.
    initial_state =
      strip_creators_from_power_levels(initial_state, [user_id | additional_creators])

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

  defp maybe_put_additional_creators(content, []), do: content

  defp maybe_put_additional_creators(content, list),
    do: Map.put(content, "additional_creators", list)

  defp strip_creators_from_power_levels(initial_state, creator_ids) do
    Enum.map(initial_state, fn
      %{"type" => "m.room.power_levels", "content" => content} = ev ->
        users = Map.drop(content["users"] || %{}, creator_ids)
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
