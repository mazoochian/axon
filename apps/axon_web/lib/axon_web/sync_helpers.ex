defmodule AxonWeb.SyncHelpers do
  @moduledoc """
  Cursor parsing and extension-building logic shared between classic
  `/sync` (`AxonWeb.SyncController`) and sliding sync
  (`AxonWeb.SlidingSyncController`). Kept as a single implementation so the
  two endpoints can't drift apart on E2EE/device-list/ephemeral semantics —
  exactly the class of relay-reliability bug fixed across Phases 8-9.
  """

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, KeyStore, Repo}
  alias AxonSync.Presence

  # Token format: "${room_ordering}_${dl_cursor}_${ad_cursor}_${pr_cursor}_${left_cursor}_${eph_cursor}"
  # dl_cursor tracks device_list_updates.id; ad_cursor tracks account_data_stream.id;
  # pr_cursor tracks AxonSync.Presence's version counter; left_cursor tracks
  # device_list_partings.id; eph_cursor tracks ephemeral_updates.id (typing/receipts).
  # Older, shorter tokens default the missing cursor(s) to 0 (return
  # everything for that stream on the next sync).
  def parse_token(nil), do: {0, 0, 0, 0, 0, 0}

  def parse_token(since) do
    parse_int = fn s ->
      case Integer.parse(s) do
        {n, _} -> n
        _ -> 0
      end
    end

    parts = String.split(since, "_")
    room_n = parse_int.(Enum.at(parts, 0, "0"))
    dl_n = parse_int.(Enum.at(parts, 1, "0"))
    ad_n = parse_int.(Enum.at(parts, 2, "0"))
    pr_n = parse_int.(Enum.at(parts, 3, "0"))
    left_n = parse_int.(Enum.at(parts, 4, "0"))
    eph_n = parse_int.(Enum.at(parts, 5, "0"))
    {room_n, dl_n, ad_n, pr_n, left_n, eph_n}
  end

  def build_token(room_ordering, dl, ad, pr, left, eph) do
    "#{room_ordering}_#{dl}_#{ad}_#{pr}_#{left}_#{eph}"
  end

  def current_dl_max_id do
    Repo.one(from(u in "device_list_updates", select: max(u.id))) || 0
  end

  def current_ad_max_id do
    Repo.one(from(s in "account_data_stream", select: max(s.id))) || 0
  end

  def current_left_max_id do
    Repo.one(from(p in "device_list_partings", select: max(p.id))) || 0
  end

  def current_eph_max_id do
    Repo.one(from(e in "ephemeral_updates", select: max(e.id))) || 0
  end

  def has_ephemeral_change?(room_id, eph_since) do
    Repo.exists?(
      from(e in "ephemeral_updates", where: e.room_id == ^room_id and e.id > ^eph_since)
    )
  end

  # Atomically fetch and delete pending to-device messages for this device.
  # Returns {events_list, max_id_delivered}.
  def drain_to_device_messages(user_id, device_id, limit \\ 100) do
    rows =
      Repo.all(
        from(m in "to_device_messages",
          where: m.target_user_id == ^user_id and m.target_device_id == ^device_id,
          order_by: [asc: m.id],
          limit: ^limit,
          select: %{id: m.id, sender: m.sender, type: m.type, content: m.content}
        )
      )

    if rows != [] do
      ids = Enum.map(rows, & &1.id)
      Repo.delete_all(from(m in "to_device_messages", where: m.id in ^ids))
    end

    events =
      Enum.map(rows, fn row ->
        %{"type" => row.type, "sender" => row.sender, "content" => row.content}
      end)

    max_id = if rows == [], do: 0, else: List.last(rows).id
    {events, max_id}
  end

  def get_otk_counts(user_id, device_id) do
    Repo.all(
      from(k in "one_time_keys",
        where: k.user_id == ^user_id and k.device_id == ^device_id and k.claimed == false,
        group_by: k.algorithm,
        select: {k.algorithm, count(k.id)}
      )
    )
    |> Enum.into(%{})
  end

  # Returns list of algorithm names for which an unused fallback key exists.
  def get_unused_fallback_key_types(user_id, device_id) do
    Repo.all(
      from(fk in "fallback_keys",
        where: fk.user_id == ^user_id and fk.device_id == ^device_id and fk.used == false,
        select: fk.algorithm
      )
    )
  end

  # Returns %{"changed" => [...], "left" => [...]}.
  def get_device_list_changes(user_id, dl_since, left_since) do
    candidate_users = [user_id | shared_room_user_ids(user_id)]

    changed =
      Repo.all(
        from(u in "device_list_updates",
          where: u.user_id in ^candidate_users and u.id > ^dl_since,
          select: u.user_id,
          distinct: true
        )
      )

    left = KeyStore.device_list_partings_since(user_id, left_since)

    %{"changed" => changed, "left" => left}
  end

  def shared_room_user_ids(user_id) do
    Repo.all(
      from(m2 in "room_memberships",
        join: m1 in "room_memberships",
        on: m1.room_id == m2.room_id and m1.user_id == ^user_id and m1.membership == "join",
        where: m2.membership == "join" and m2.user_id != ^user_id,
        select: m2.user_id,
        distinct: true
      )
    )
  end

  # Initial sync: return all account_data for the user.
  # Incremental sync: return only types that changed since ad_since (account_data_stream cursor).
  def get_global_account_data(user_id, _is_initial = true, _ad_since) do
    Repo.all(
      from(a in "account_data",
        where: a.user_id == ^user_id,
        select: %{type: a.type, content: a.content}
      )
    )
    |> Enum.map(fn a -> %{"type" => a.type, "content" => a.content} end)
  end

  def get_global_account_data(user_id, _is_initial = false, ad_since) do
    changed_types =
      Repo.all(
        from(s in "account_data_stream",
          where: s.user_id == ^user_id and s.id > ^ad_since,
          select: s.type,
          distinct: true
        )
      )

    if changed_types == [] do
      []
    else
      Repo.all(
        from(a in "account_data",
          where: a.user_id == ^user_id and a.type in ^changed_types,
          select: %{type: a.type, content: a.content}
        )
      )
      |> Enum.map(fn a -> %{"type" => a.type, "content" => a.content} end)
    end
  end

  def build_room_account_data(room_id, user_id) do
    Repo.all(
      from(r in "room_account_data",
        where: r.room_id == ^room_id and r.user_id == ^user_id,
        select: %{type: r.type, content: r.content}
      )
    )
    |> Enum.map(fn r -> %{"type" => r.type, "content" => r.content} end)
  end

  def build_receipt_events(room_id) do
    receipts =
      Repo.all(
        from(r in "receipts",
          where: r.room_id == ^room_id and r.receipt_type in ["m.read", "m.read.private"],
          select: %{
            user_id: r.user_id,
            receipt_type: r.receipt_type,
            event_id: r.event_id,
            ts: r.ts
          }
        )
      )

    if receipts == [] do
      []
    else
      content =
        Enum.reduce(receipts, %{}, fn r, acc ->
          user_entry = %{"ts" => r.ts}
          type_map = Map.get(acc, r.event_id, %{})
          users_map = Map.get(type_map, r.receipt_type, %{})

          updated_type_map =
            Map.put(type_map, r.receipt_type, Map.put(users_map, r.user_id, user_entry))

          Map.put(acc, r.event_id, updated_type_map)
        end)

      [%{"type" => "m.receipt", "content" => content}]
    end
  end

  # Unlike receipts (only included when non-empty), typing is included with
  # an empty user_ids list on an *incremental* sync — the room only got
  # there because something ephemeral changed, so an empty list is itself
  # meaningful ("someone stopped typing", vs. absent meaning "nothing to
  # report"). An *initial* sync includes every joined room regardless of
  # any ephemeral change (build_rooms_response/6 doesn't gate on one), so
  # there's no such transition to report there — an empty typing entry
  # would be attached to every single joined room on every initial sync,
  # which is exactly what a room denied by ACL (m.room.server_acl) must
  # NOT still leak: Complement's TestACLsForEDUs asserts a denied room's
  # `ephemeral.events` is empty, not `[{"type": "m.typing", "content":
  # {"user_ids": []}}]`.
  def build_typing_event(room_id, is_initial_sync \\ false) do
    user_ids = AxonSync.Typing.typing_user_ids(room_id)

    if user_ids == [] and is_initial_sync do
      []
    else
      [%{"type" => "m.typing", "content" => %{"user_ids" => user_ids}}]
    end
  end

  # Presence for the user themselves plus anyone sharing a joined room with
  # them. Initial sync returns everyone's current state; incremental sync
  # returns only those whose presence changed since pr_since.
  def get_presence_events(user_id, is_initial_sync, pr_since) do
    candidate_users = [user_id | shared_room_user_ids(user_id)]

    presence_by_user =
      if is_initial_sync do
        Enum.into(candidate_users, %{}, fn uid -> {uid, Presence.get(uid)} end)
      else
        Presence.changes_since(candidate_users, pr_since)
      end

    Enum.map(presence_by_user, fn {uid, presence} ->
      %{"type" => "m.presence", "sender" => uid, "content" => presence}
    end)
  end

  @doc "True if the room has any m.room.encryption state event."
  def room_encrypted?(room_id) do
    EventStore.get_state_event(room_id, "m.room.encryption", "") != {:error, :not_found}
  end

  @doc """
  Stripped preview state for an invited room, plus `user_id`'s own invite
  `m.room.member` event — the shape both classic `/sync`'s `invite_state`
  and sliding sync's `invite_state` use, so the two can't drift on what an
  invitee is allowed to see before joining.
  """
  def build_invite_state(room_id, user_id) do
    # Real current_room_state, when we have any — true for a same-server
    # invite (the inviting server is resident with full state) or a room
    # we used to be joined to. Falls back to the invite_room_state preview
    # the *inviting* server handed us for a purely federated invite, where
    # this is the only state we have ever seen for the room at all.
    stripped =
      case EventStore.stripped_state_events(room_id) do
        [] -> EventStore.get_invite_preview_state(room_id, user_id)
        events -> events
      end

    case EventStore.get_state_event(room_id, "m.room.member", user_id) do
      {:ok, invite_event} -> stripped ++ [stripped_event(invite_event)]
      _ -> stripped
    end
  end

  defp stripped_event(event) do
    %{
      "type" => event.type,
      "state_key" => event.state_key,
      "sender" => event.sender,
      "content" => event.content || %{}
    }
  end
end
