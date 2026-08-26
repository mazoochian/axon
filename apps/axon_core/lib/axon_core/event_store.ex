defmodule AxonCore.EventStore do
  @moduledoc """
  All database operations for the Matrix event store.

  The events table is append-only. State is derived from events and
  maintained in current_room_state for fast lookup.
  """

  import Ecto.Query
  alias AxonCore.{KeyStore, Repo}
  alias AxonCore.Schema.{Event, Room, RoomMembership}

  # ---------------------------------------------------------------------------
  # Event insertion (the critical path)
  # ---------------------------------------------------------------------------

  @doc """
  Atomically inserts an *accepted* event and updates derived state tables.

  The event map should be a fully-signed, finalized Matrix event map
  (with event_id, signatures, hashes set).

  If a row for this event_id already exists and was previously stored via
  `insert_rejected_event/2` (`rejected: true`), calling this "unrejects"
  it: the row is flipped to `rejected: false`/`soft_failed: false` *and*
  given a fresh `stream_ordering`. The fresh ordering matters — without
  it, the event would keep sorting at its original (rejected-era)
  position, which is very likely already before any `since` token a
  client captured in the meantime, so it would never appear as a new
  event down `/sync` (see `TestUnrejectRejectedEvents`: event B is
  rejected while its prev_event is missing, then resent once that gap is
  closed and must appear as a new timeline event, not backdated).

  An idempotent resend of an event that's already accepted (not
  previously rejected) is unaffected: the ordering bump only fires on an
  actual rejected -> accepted transition.

  A row that already exists as **soft-failed**, by contrast, is never
  touched at all — not even to leave it soft-failed while otherwise
  proceeding. `insert_soft_failed_event/2`'s one-time-determination
  guarantee ("matching Synapse's own... behavior") has to hold no matter
  which of this module's several callers re-presents the same event_id
  later (`AxonRoom.RoomProcess.apply_remote_event/2` re-running its own
  auth check on a retried/backfilled PDU is the common case, but
  `AxonFederation.RoomJoin`/`RoomKnock`/`RoomLeave` and
  `AxonWeb.FederationController` all call this function directly too), so
  it's enforced once here rather than relying on every call site to
  re-check first. Without this, a caller that independently decides the
  retried event is authorized against *some* current state would resolve
  the on_conflict below and both flip `soft_failed` back to `false` *and*
  re-run the state/membership writes — silently promoting an event the
  soft-fail determination said must never advance room state.
  """
  def insert_event(event_map, room_version) do
    params = Event.from_wire(event_map, room_version)

    case Repo.get_by(Event, event_id: params.event_id) do
      %Event{soft_failed: true} = already_soft_failed ->
        {:ok, already_soft_failed}

      _ ->
        do_insert_event(event_map, params)
    end
  end

  defp do_insert_event(event_map, params) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:existing, fn repo, _ ->
      {:ok, repo.get_by(Event, event_id: params.event_id)}
    end)
    |> Ecto.Multi.insert(:event_raw, Event.changeset(%Event{}, params),
      on_conflict: [set: [rejected: false, soft_failed: false]],
      conflict_target: :event_id
    )
    |> Ecto.Multi.run(:event, fn repo, %{event_raw: _raw} ->
      # Reload to get DB-assigned stream_ordering (BIGSERIAL).
      # Also handles the on_conflict case — we still need the persisted row.
      case repo.get_by(Event, event_id: params.event_id) do
        nil -> {:error, :event_not_found}
        event -> {:ok, event}
      end
    end)
    |> Ecto.Multi.run(:unreject, fn repo, %{existing: existing, event: event} ->
      if existing && existing.rejected do
        repo.update_all(
          from(e in Event,
            where: e.event_id == ^event.event_id,
            update: [set: [stream_ordering: fragment("nextval('events_stream_ordering_seq')")]]
          ),
          []
        )

        case repo.get_by(Event, event_id: event.event_id) do
          nil -> {:error, :event_not_found}
          refreshed -> {:ok, refreshed}
        end
      else
        {:ok, event}
      end
    end)
    |> Ecto.Multi.run(:state, fn repo, %{unreject: event} ->
      update_current_state(repo, event)
    end)
    |> Ecto.Multi.run(:membership, fn repo, %{unreject: event} ->
      update_membership(repo, event)
    end)
    |> Ecto.Multi.run(:room_upgrade_push_rules, fn repo, %{unreject: event} ->
      maybe_copy_room_push_rules(repo, event)
    end)
    |> Ecto.Multi.run(:auth_edges, fn repo, %{unreject: event} ->
      insert_auth_edges(repo, event)
    end)
    |> Ecto.Multi.run(:redaction, fn repo, %{unreject: event} ->
      maybe_apply_redaction(repo, event_map, event)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{unreject: event}} -> {:ok, event}
      {:error, :event_raw, changeset, _} -> {:error, changeset}
      {:error, step, reason, _} -> {:error, {step, reason}}
    end
  end

  # An `m.room.redaction` event is always accepted and stored like any other
  # event (per spec, redaction is never an auth-rule concern) — but whether
  # the target event's *content* actually gets stripped is a separate,
  # server-local policy decision: only if the redacter is the target's
  # original sender or holds the room's `redact` power level. `redacts` is a
  # top-level wire field through room version 10 and moves into
  # `content.redacts` from v11 (MSC2174), so both are checked against the
  # original wire map — neither is a column on the stored row.
  defp maybe_apply_redaction(repo, event_map, %Event{type: "m.room.redaction"} = redaction_event) do
    target_id = event_map["redacts"] || get_in(event_map, ["content", "redacts"])

    with true <- is_binary(target_id),
         %Event{} = target <- repo.get_by(Event, event_id: target_id),
         true <- redaction_permitted?(redaction_event.sender, target) do
      redacted_content =
        target
        |> event_to_map()
        |> AxonCrypto.Redaction.redact(target.room_version)
        |> Map.fetch!("content")

      repo.update_all(
        from(e in Event, where: e.event_id == ^target_id),
        set: [
          content: redacted_content,
          redacted: true,
          redacted_because: redaction_event.event_id
        ]
      )
    end

    {:ok, :ok}
  end

  defp maybe_apply_redaction(_repo, _event_map, _event), do: {:ok, :ok}

  defp redaction_permitted?(sender, target) do
    sender == target.sender or has_redact_power?(target.room_id, sender)
  end

  defp has_redact_power?(room_id, user_id) do
    pl =
      case get_current_state_map(room_id)[{"m.room.power_levels", ""}] do
        nil -> %{}
        event -> event["content"] || %{}
      end

    required = Map.get(pl, "redact", 50)
    users = Map.get(pl, "users", %{})
    Map.get(users, user_id, Map.get(pl, "users_default", 0)) >= required
  end

  @doc """
  Persists an event that failed auth-checking (or whose ancestry could not
  be resolved) as **rejected**.

  Per spec, a rejected event is still *stored* (so `GET /event/{id}` and
  `/event_auth` chain walks can see it, and it can later be "unrejected" —
  see `insert_event/2`) but it is never applied to derived state: no
  `current_room_state`/`room_memberships` row is written, so it is
  invisible to `/state`, `/state_ids`, state resolution, and — via the
  `not e.rejected` filters throughout this module — `/sync`, `/messages`
  and friends.

  If the event_id already exists as a **non**-rejected (already-applied)
  event, this is a no-op that leaves the existing row untouched —
  rejection must never downgrade an event that was already correctly
  applied.
  """
  def insert_rejected_event(event_map, room_version) do
    params =
      event_map
      |> Event.from_wire(room_version)
      |> Map.put(:rejected, true)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:event_raw, Event.changeset(%Event{}, params),
      on_conflict: :nothing,
      conflict_target: :event_id
    )
    |> Ecto.Multi.run(:event, fn repo, %{event_raw: _raw} ->
      case repo.get_by(Event, event_id: params.event_id) do
        nil -> {:error, :event_not_found}
        event -> {:ok, event}
      end
    end)
    |> Ecto.Multi.run(:auth_edges, fn repo, %{event: event} ->
      insert_auth_edges(repo, event)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{event: event}} -> {:ok, event}
      {:error, :event_raw, changeset, _} -> {:error, changeset}
      {:error, step, reason, _} -> {:error, {step, reason}}
    end
  end

  @doc """
  Persists an event that failed auth-checking against the room's *current*
  live state, despite passing auth-checking against the state as of its
  own ancestry, as **soft-failed**.

  This is the second, softer check `insert_rejected_event/2`'s moduledoc
  refers to — distinct from outright rejection, which means the event was
  never valid at all. A soft-failed event was legitimately authorized by
  whoever sent it, based on what they knew of the room at the time; it
  only conflicts with state that changed here (via some other event)
  after they built it, most commonly a concurrent fork resolving against
  them (e.g. sent while their own power was being revoked from a
  different branch of the DAG). Per spec it must still be treated as a
  genuine part of the room's history — a future event may legitimately
  reference it as a `prev_event` or resolve state through it — just never
  shown to a client directly and never advances the local room head.

  Same non-application semantics as `insert_rejected_event/2` (no
  `current_room_state`/`room_memberships` write; invisible to `/sync`,
  `/messages`, `/state` via the `not e.soft_failed` filters throughout
  this module) but, unlike rejection, there is no "un-soft-fail" — this
  is a one-time determination made against state as it stood at receipt,
  not something a later-arriving event can retroactively undo (matching
  Synapse's own behavior).

  Same no-op-if-already-accepted guard as `insert_rejected_event/2`.
  """
  def insert_soft_failed_event(event_map, room_version) do
    params =
      event_map
      |> Event.from_wire(room_version)
      |> Map.put(:soft_failed, true)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:event_raw, Event.changeset(%Event{}, params),
      on_conflict: :nothing,
      conflict_target: :event_id
    )
    |> Ecto.Multi.run(:event, fn repo, %{event_raw: _raw} ->
      case repo.get_by(Event, event_id: params.event_id) do
        nil -> {:error, :event_not_found}
        event -> {:ok, event}
      end
    end)
    |> Ecto.Multi.run(:auth_edges, fn repo, %{event: event} ->
      insert_auth_edges(repo, event)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{event: event}} -> {:ok, event}
      {:error, :event_raw, changeset, _} -> {:error, changeset}
      {:error, step, reason, _} -> {:error, {step, reason}}
    end
  end

  @doc "True if any of `event_ids` is a stored, rejected event."
  def any_rejected?([]), do: false

  def any_rejected?(event_ids) do
    Repo.exists?(from(e in Event, where: e.event_id in ^event_ids and e.rejected))
  end

  @doc """
  The subset of `event_ids` that are not stored locally at all — neither
  accepted nor rejected. Distinct from `any_rejected?/1`: that only catches
  an `auth_events` reference to an event we've *seen and rejected*; this
  catches a reference to one we've never seen, which per spec cannot be
  authorized either (there's no auth chain to have verified). Used by
  `AxonRoom.RoomProcess` to fail closed on an inbound PDU whose auth_events
  point at something we have no record of at all, same as it already does
  for a *known*-rejected one.
  """
  def unknown_ids([]), do: []

  def unknown_ids(event_ids) do
    known =
      Repo.all(from(e in Event, where: e.event_id in ^event_ids, select: e.event_id))
      |> MapSet.new()

    Enum.reject(event_ids, &MapSet.member?(known, &1))
  end

  defp update_current_state(_repo, %Event{state_key: nil}), do: {:ok, nil}

  defp update_current_state(repo, event) do
    repo.insert_all(
      "current_room_state",
      [
        %{
          room_id: event.room_id,
          type: event.type,
          state_key: event.state_key,
          event_id: event.event_id
        }
      ],
      on_conflict: {:replace, [:event_id]},
      conflict_target: [:room_id, :type, :state_key]
    )

    {:ok, nil}
  end

  defp update_membership(_repo, %Event{type: type}) when type != "m.room.member", do: {:ok, nil}

  defp update_membership(repo, event) do
    membership = get_in(event.content, ["membership"])
    target_user_id = event.state_key

    if membership && target_user_id do
      previous_membership =
        repo.one(
          from(m in "room_memberships",
            where: m.room_id == ^event.room_id and m.user_id == ^target_user_id,
            select: m.membership
          )
        )

      repo.insert_all(
        "room_memberships",
        [
          %{
            room_id: event.room_id,
            user_id: target_user_id,
            membership: membership,
            event_id: event.event_id,
            sender: event.sender,
            display_name: get_in(event.content, ["displayname"]),
            avatar_url: get_in(event.content, ["avatar_url"]),
            forgotten: false,
            inserted_at: DateTime.utc_now(:microsecond),
            updated_at: DateTime.utc_now(:microsecond)
          }
        ],
        on_conflict:
          {:replace,
           [:membership, :event_id, :sender, :display_name, :avatar_url, :forgotten, :updated_at]},
        conflict_target: [:room_id, :user_id]
      )

      notify_device_lists(repo, event.room_id, target_user_id, previous_membership, membership)

      {:ok, nil}
    else
      {:ok, nil}
    end
  end

  # A room-upgrade link is only trustworthy once *both* sides of it agree —
  # the successor's accepted `m.room.create` names the old room as
  # predecessor, and the old room's accepted `m.room.tombstone` names the
  # successor as replacement_room — checked against **current** state rather
  # than the single triggering event, since either side can arrive first
  # (a same-server upgrade sends the tombstone first; a v12/federated
  # create-first flow, or a remote join that only imports the successor's
  # state, learns the create first) and the other may not exist locally yet.
  # Reconciliation is therefore invoked from both event types below, and is a
  # no-op until the current state actually has both sides matching. Keeping
  # this beside event persistence, in the same transaction as the state
  # update, means locally-created upgrades and links learned via federation
  # take the same path. The copy never replaces a rule already configured
  # for the successor.
  defp maybe_copy_room_push_rules(repo, %Event{
         type: "m.room.create",
         state_key: "",
         room_id: new_room_id,
         content: %{"predecessor" => %{"room_id" => old_room_id}}
       })
       when is_binary(old_room_id) and old_room_id != new_room_id do
    reconcile_room_upgrade_push_rules(repo, old_room_id, new_room_id)
  end

  defp maybe_copy_room_push_rules(repo, %Event{
         type: "m.room.tombstone",
         state_key: "",
         room_id: old_room_id,
         content: %{"replacement_room" => new_room_id}
       })
       when is_binary(new_room_id) and new_room_id != old_room_id do
    reconcile_room_upgrade_push_rules(repo, old_room_id, new_room_id)
  end

  defp maybe_copy_room_push_rules(_repo, _event), do: {:ok, :ok}

  defp reconcile_room_upgrade_push_rules(repo, old_room_id, new_room_id) do
    with true <- valid_room_id?(old_room_id) and valid_room_id?(new_room_id),
         %Event{} = create <- current_state_event(repo, new_room_id, "m.room.create", ""),
         ^old_room_id <- get_in(create.content, ["predecessor", "room_id"]),
         %Event{} = tombstone <- current_state_event(repo, old_room_id, "m.room.tombstone", ""),
         ^new_room_id <- tombstone.content["replacement_room"],
         true <- predecessor_event_id_matches?(create, tombstone) do
      copy_room_push_rules(repo, old_room_id, new_room_id)
    end

    {:ok, :ok}
  end

  defp predecessor_event_id_matches?(create, tombstone) do
    case get_in(create.content, ["predecessor", "event_id"]) do
      nil -> true
      event_id -> event_id == tombstone.event_id
    end
  end

  # The current (accepted, non-rejected) state event for {room_id, type,
  # state_key} — same notion `get_state_event/3` exposes, but taking the
  # in-transaction `repo` explicitly like this module's other Multi steps
  # rather than going through the public `Repo`-bound function.
  defp current_state_event(repo, room_id, type, state_key) do
    repo.one(
      from(e in Event,
        join: s in "current_room_state",
        on:
          s.event_id == e.event_id and s.room_id == ^room_id and s.type == ^type and
            s.state_key == ^state_key,
        where: not e.rejected,
        select: e
      )
    )
  end

  defp copy_room_push_rules(repo, old_room_id, new_room_id) do
    rows =
      repo.all(
        from(rule in "user_push_rules",
          join: membership in "room_memberships",
          on:
            membership.user_id == rule.user_id and membership.room_id == ^old_room_id and
              membership.membership == "join",
          join: user in "users",
          on: user.user_id == rule.user_id,
          where: rule.kind == "room" and rule.rule_id == ^old_room_id,
          select: %{
            user_id: rule.user_id,
            kind: "room",
            rule_id: ^new_room_id,
            is_default: rule.is_default,
            pattern: rule.pattern,
            conditions: rule.conditions,
            actions: rule.actions,
            enabled: rule.enabled,
            inserted_at: rule.inserted_at
          }
        )
      )

    repo.insert_all("user_push_rules", rows,
      on_conflict: :nothing,
      conflict_target: [:user_id, :kind, :rule_id]
    )
  end

  defp valid_room_id?("!" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [localpart, server] -> localpart != "" and server != ""
      _ -> false
    end
  end

  defp valid_room_id?(_), do: false

  # A user newly joining a room now shares it with every other current
  # member — per spec, /sync device_lists.changed and /keys/changes must
  # reflect that even if none of their keys actually changed. Re-touching
  # device_list_updates for everyone involved (the existing "keys changed"
  # signal) achieves this without a separate mechanism: it wakes any
  # long-polling /sync and gives both sides a fresh cursor position.
  defp notify_device_lists(repo, room_id, user_id, previous_membership, "join")
       when previous_membership != "join" do
    other_members = other_joined_members(repo, room_id, user_id)

    KeyStore.record_device_list_update(user_id)
    Enum.each(other_members, &KeyStore.record_device_list_update/1)
  end

  # A user leaving/being removed no longer shares this room with its other
  # members. If that was the only room they shared, record an explicit
  # "parting" for device_lists.left — unlike `changed`, this can't be
  # derived from current membership, since by definition the parted pair no
  # longer shares any room to query.
  defp notify_device_lists(repo, room_id, user_id, "join", new_membership)
       when new_membership != "join" do
    other_members = other_joined_members(repo, room_id, user_id)

    Enum.each(other_members, fn other_id ->
      unless shares_another_room?(repo, user_id, other_id, room_id) do
        KeyStore.record_device_list_parting(other_id, user_id)
        KeyStore.record_device_list_parting(user_id, other_id)
      end
    end)
  end

  defp notify_device_lists(_repo, _room_id, _user_id, _previous, _new), do: :ok

  defp other_joined_members(repo, room_id, excluding_user_id) do
    repo.all(
      from(m in "room_memberships",
        where:
          m.room_id == ^room_id and m.membership == "join" and m.user_id != ^excluding_user_id,
        select: m.user_id
      )
    )
  end

  defp shares_another_room?(repo, user_a, user_b, excluding_room_id) do
    repo.exists?(
      from(m1 in "room_memberships",
        join: m2 in "room_memberships",
        on: m1.room_id == m2.room_id,
        where:
          m1.user_id == ^user_a and m1.membership == "join" and
            m2.user_id == ^user_b and m2.membership == "join" and
            m1.room_id != ^excluding_room_id
      )
    )
  end

  defp insert_auth_edges(_repo, %Event{auth_event_ids: []}), do: {:ok, nil}

  defp insert_auth_edges(repo, event) do
    rows =
      Enum.map(event.auth_event_ids, fn auth_id ->
        %{event_id: event.event_id, auth_event_id: auth_id}
      end)

    repo.insert_all("event_auth_edges", rows, on_conflict: :nothing)
    {:ok, nil}
  end

  # ---------------------------------------------------------------------------
  # Room creation
  # ---------------------------------------------------------------------------

  def insert_room(room_id, creator, version \\ "11", is_public \\ false) do
    %Room{}
    |> Room.changeset(%{
      room_id: room_id,
      creator: creator,
      version: version,
      is_public: is_public
    })
    |> Repo.insert()
  end

  def get_room(room_id) do
    case Repo.get(Room, room_id) do
      nil -> {:error, :not_found}
      room -> {:ok, room}
    end
  end

  @doc """
  A room's version, or `default` when the room isn't known locally.

  Needed wherever a signature must be verified or an event ID computed for a
  room this server may only be learning about (backfill, an inbound PDU for a
  room we're joining) — both are redaction-dependent, and the redaction
  algorithm is version-specific.
  """
  def get_room_version(room_id, default \\ "11") do
    case Repo.one(from(r in Room, where: r.room_id == ^room_id, select: r.version)) do
      nil -> default
      version -> version
    end
  end

  @doc "Whether room_id has been purged/blocked by a server admin (AdminController.purge_room/2)."
  def room_blocked?(room_id) do
    Repo.one(from(r in Room, where: r.room_id == ^room_id, select: r.blocked)) || false
  end

  @doc """
  Admin room deletion: removes the room's events, state, memberships, and
  other room-scoped rows from local storage, and marks it blocked so a
  future join attempt gets a clear, specific rejection instead of either
  silently doing nothing or (worse) recreating a room nobody actually
  administers under the same id. The `rooms` row itself is kept — it's the
  tombstone that `blocked` lives on, and nothing else references its
  deletion via a cascading FK, so removing it would just orphan any
  remaining child data anyway.
  """
  def purge_room(room_id) do
    Repo.transaction(fn ->
      Repo.delete_all(from(e in Event, where: e.room_id == ^room_id))
      Repo.delete_all(from(s in "current_room_state", where: s.room_id == ^room_id))
      Repo.delete_all(from(s in "room_state_snapshots", where: s.room_id == ^room_id))
      Repo.delete_all(from(m in RoomMembership, where: m.room_id == ^room_id))
      Repo.delete_all(from(a in "room_aliases", where: a.room_id == ^room_id))
      Repo.delete_all(from(a in "room_account_data", where: a.room_id == ^room_id))
      Repo.delete_all(from(r in "receipts", where: r.room_id == ^room_id))
      Repo.delete_all(from(e in "ephemeral_updates", where: e.room_id == ^room_id))
      Repo.update_all(from(r in Room, where: r.room_id == ^room_id), set: [blocked: true])
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Event queries
  # ---------------------------------------------------------------------------

  def get_event(event_id) do
    case Repo.get_by(Event, event_id: event_id) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  @doc """
  Like `get_event/1`, but for client-facing reads: an event that is
  `rejected` or `soft_failed` is treated as not found, matching the
  `not e.rejected and not e.soft_failed` filters used throughout this
  module's other client-facing queries (`get_events_since/2`,
  `get_messages/2`, etc).

  `get_event/1` itself must stay unfiltered — per `insert_rejected_event/2`'s
  doc comment, federation's `GET /event/{id}` and `/event_auth` chain walks
  need to keep seeing rejected events so peer servers can resolve auth
  chains — so this is a separate function rather than a change to
  `get_event/1`. Use this one from any client API path (`GET
  /rooms/{roomId}/event/{eventId}` and friends); use `get_event/1` only for
  federation-facing or internal callers that legitimately need to see
  rejected/soft-failed events too.
  """
  def get_visible_event(event_id) do
    case Repo.get_by(Event, event_id: event_id) do
      nil -> {:error, :not_found}
      %Event{rejected: true} -> {:error, :not_found}
      %Event{soft_failed: true} -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  @doc "Returns events in a room with stream_ordering > since, in order."
  def get_events_since(room_id, since_ordering, limit \\ 100) do
    Repo.all(
      from(e in Event,
        where:
          e.room_id == ^room_id and
            e.stream_ordering > ^since_ordering and
            not e.rejected and
            not e.soft_failed,
        order_by: [asc: e.stream_ordering],
        limit: ^limit
      )
    )
  end

  @doc """
  Paginate room history (for GET /rooms/:id/messages).

  `dir == "b"` orders by `depth` (the event's true DAG position) first,
  breaking ties with `stream_ordering` (insertion order). `stream_ordering`
  alone is assigned at local DB-insert time, not at DAG-creation time — a
  remote event can be created early (low `depth`, computed from its real
  `prev_events`) but only transmitted/inserted locally late (after the local
  room head has already advanced), landing it a high `stream_ordering`. A
  backward page ordered purely by `desc: stream_ordering` would surface that
  event near the top of the page — looking "recent" — even though it
  topologically belongs much further back. Ordering by `depth` first fixes
  that; the `stream_ordering` tiebreak only disambiguates events that share a
  depth (concurrent/forked events), mirroring Synapse's topological+stream
  ordering.

  The `WHERE e.stream_ordering < ^from_ordering` bound (windowing/pagination)
  is intentionally left as `stream_ordering`-based — only the ordering of
  events within that window changes, not which events are eligible for the
  page.

  `dir == "f"` (forward) is unaffected: it still orders by `stream_ordering`
  alone, since forward pagination has no analogous bug (it walks strictly in
  local insertion order, which is what a `since`-token-based cursor needs).
  """
  def get_messages(room_id, from_ordering, dir, limit \\ 10) do
    base =
      from(e in Event,
        where: e.room_id == ^room_id and not e.rejected and not e.soft_failed
      )

    query =
      case dir do
        "b" ->
          from(e in base,
            where: e.stream_ordering < ^from_ordering,
            order_by: [desc: e.depth, desc: e.stream_ordering],
            limit: ^limit
          )

        _ ->
          from(e in base,
            where: e.stream_ordering > ^from_ordering,
            order_by: [asc: e.stream_ordering],
            limit: ^limit
          )
      end

    Repo.all(query)
  end

  @doc """
  Events strictly on one side of `event` in true DAG order — powers GET
  /rooms/:id/context's `events_before`/`events_after` windowing.

  Unlike `get_messages/4`, whose `WHERE` bound is deliberately
  `stream_ordering`-only (appropriate there because its `from_ordering` comes
  from a pagination *token* whose own position was already established
  relative to a known-good window), here the pivot is `event` itself — and
  `event` can be a federation-backfilled event, where `stream_ordering`
  means nothing about DAG position (see `get_messages/4`'s doc). Bounding
  purely by `event.stream_ordering`, as `get_context/2` used to (by reusing
  `get_messages/4` with `event.stream_ordering` as `from_ordering`), silently
  gets both sides wrong for such an event: a member who joined *after*
  `event` but got inserted locally *before* it backfilled in (low
  `stream_ordering`, high `depth`) wrongly counts as "before" `event`; an
  ancestor of `event` that only backfills in *after* `event` was already
  known (high `stream_ordering`, low `depth`) wrongly counts as "after" it.

  Comparing the full `{depth, stream_ordering}` tuple against `event`'s own
  fixes both: `dir == "b"` wants strictly lower `depth` (ties on `depth`
  broken by lower `stream_ordering`), `dir == "f"` the mirror image.
  """
  def get_context_neighbors(room_id, %Event{} = event, dir, limit) do
    base =
      from(e in Event,
        where: e.room_id == ^room_id and not e.rejected and not e.soft_failed
      )

    query =
      case dir do
        "b" ->
          from(e in base,
            where:
              e.depth < ^event.depth or
                (e.depth == ^event.depth and e.stream_ordering < ^event.stream_ordering),
            order_by: [desc: e.depth, desc: e.stream_ordering],
            limit: ^limit
          )

        _ ->
          from(e in base,
            where:
              e.depth > ^event.depth or
                (e.depth == ^event.depth and e.stream_ordering > ^event.stream_ordering),
            order_by: [asc: e.depth, asc: e.stream_ordering],
            limit: ^limit
          )
      end

    Repo.all(query)
  end

  @doc """
  The event closest to `ts` (ms since the epoch) in `dir` — `"f"` for the
  earliest event at or after it, `"b"` for the latest at or before it. Backs
  GET /rooms/:id/timestamp_to_event.

  Ties on `origin_server_ts` break by `stream_ordering`, so a room whose events
  all carry the same timestamp (bridged/imported history, or just a fast
  sender) still resolves to the topologically nearest event in the requested
  direction rather than an arbitrary one of the tied set.
  """
  def find_event_by_timestamp(room_id, ts, dir) do
    base =
      from(e in Event,
        where: e.room_id == ^room_id and not e.rejected and not e.soft_failed
      )

    query =
      case dir do
        "b" ->
          from(e in base,
            where: e.origin_server_ts <= ^ts,
            order_by: [desc: e.origin_server_ts, desc: e.stream_ordering],
            limit: 1
          )

        _ ->
          from(e in base,
            where: e.origin_server_ts >= ^ts,
            order_by: [asc: e.origin_server_ts, asc: e.stream_ordering],
            limit: 1
          )
      end

    Repo.one(query)
  end

  @doc """
  The `stream_ordering` of the earliest (not rejected/soft-failed) event
  this server knows about in `room_id`, or `nil` if it knows none at all.
  Same visibility filter `find_event_by_timestamp/3` applies, so the two
  stay consistent — see `trustworthy_local_timestamp_answer?/3`.
  """
  def earliest_known_stream_ordering(room_id) do
    Repo.one(
      from(e in Event,
        where: e.room_id == ^room_id and not e.rejected and not e.soft_failed,
        select: min(e.stream_ordering)
      )
    )
  end

  @doc """
  Whether `event` — an answer `find_event_by_timestamp/3` already produced
  for `room_id` and `dir` — is trustworthy as the room's true
  globally-nearest event, or merely the nearest *this server happens to
  know about*.

  Matches Synapse's heuristic for the same problem
  (`get_event_for_timestamp`): a server's local history can fall short of
  the room's real history in either direction — most commonly a member who
  joined late. A remote join only ever imports a *state snapshot* (current
  state + auth chain, see `AxonFederation.RoomJoin.import_room_state/5`),
  never the timeline in between, so a late joiner's local history has a
  real hole in it: full knowledge of the room's state as of the join, full
  knowledge of everything sent *after* the join (ordinary live traffic),
  and nothing reliable in between. `find_event_by_timestamp/3`'s `>=`/`<=`
  comparison can't tell a genuine answer from a value that merely
  satisfies the inequality because the real answer fell in that hole — and
  the wrong answer isn't always this server's single earliest or latest
  known event either: a query landing inside the hole resolves to
  whichever *state* event happens to sit nearest the requested time (e.g.
  the late joiner's own earlier-joined roommate), which can be squarely in
  the *middle* of what this server knows by insertion order.

  Two independent signals, one per direction:

    * `dir == "f"`: distrust if `event` is this server's own earliest
      known event in the room (the plain edge-of-history case), or if it
      is missing any of its own `prev_event_ids` locally (a "backward
      gap" — proof this server never received whatever came immediately
      before it, so an earlier event that still satisfies `>= ts` may
      exist without this server's knowledge).

    * `dir == "b"`: distrust if no locally known event lists `event` in
      *its* `prev_event_ids` (a "forward gap" — proof nothing connects
      this event forward to what this server knows came later, so a
      later-but-still-`<= ts` event may exist without this server's
      knowledge). This also catches `event` being this server's own
      latest known event, since by definition nothing later can reference
      it.

  Either way, the caller treats the candidate as provisional and asks
  federation (`AxonFederation.TimestampToEvent`) before trusting it.
  """
  def trustworthy_local_timestamp_answer?(room_id, event, dir) do
    case dir do
      "f" ->
        event.stream_ordering != earliest_known_stream_ordering(room_id) and
          not backward_gap?(room_id, event)

      "b" ->
        not forward_gap?(room_id, event)
    end
  end

  # Whether `event` is missing any of its own declared `prev_event_ids`
  # from this server's local history — i.e. whether this server was ever
  # actually told what came immediately before it, as opposed to merely
  # receiving it as part of a join's state snapshot. A genuine room-root
  # event (empty `prev_event_ids`) is never a gap.
  defp backward_gap?(_room_id, %{prev_event_ids: []}), do: false

  defp backward_gap?(room_id, %{prev_event_ids: prev_event_ids}) do
    known =
      Repo.all(
        from(e in Event,
          where: e.room_id == ^room_id and e.event_id in ^prev_event_ids,
          select: e.event_id
        )
      )
      |> MapSet.new()

    Enum.any?(prev_event_ids, &(not MapSet.member?(known, &1)))
  end

  # Whether any event this server locally knows about in `room_id` lists
  # `event` as one of *its* `prev_event_ids` — i.e. whether this server
  # can see anything connecting forward from `event` toward the present.
  defp forward_gap?(room_id, event) do
    not Repo.exists?(
      from(e in Event,
        where: e.room_id == ^room_id and fragment("? = ANY(?)", ^event.event_id, e.prev_event_ids)
      )
    )
  end

  @doc """
  Paginate events related to `target_event_id` (for GET /rooms/:id/relations/:eventId).
  `rel_type` and `event_type` are optional filters, `nil` means "any".
  """
  def get_relations(
        room_id,
        target_event_id,
        rel_type,
        event_type,
        from_ordering,
        dir,
        limit \\ 10
      ) do
    base =
      from(e in Event,
        where:
          e.room_id == ^room_id and not e.rejected and not e.soft_failed and
            fragment("?->'m.relates_to'->>'event_id'", e.content) == ^target_event_id
      )

    base =
      if rel_type,
        do:
          from(e in base,
            where: fragment("?->'m.relates_to'->>'rel_type'", e.content) == ^rel_type
          ),
        else: base

    base = if event_type, do: from(e in base, where: e.type == ^event_type), else: base

    query =
      case dir do
        "f" ->
          from(e in base,
            where: e.stream_ordering > ^from_ordering,
            order_by: [asc: e.stream_ordering],
            limit: ^limit
          )

        _ ->
          from(e in base,
            where: e.stream_ordering < ^from_ordering,
            order_by: [desc: e.stream_ordering],
            limit: ^limit
          )
      end

    Repo.all(query)
  end

  @doc """
  Thread root events in `room_id` — a "root" is any event that has at
  least one other (non-rejected, non-soft-failed) event related to it via
  an `m.thread` relation, the same notion `bundle_relations/3`'s
  `m.thread` bundle already uses, reused here rather than reinvented.
  Ordered by most-recently-active thread first: the *latest* child
  event's `stream_ordering`, not the root's own position, which is why
  this can't just reuse `get_messages/4`'s plain timeline ordering.

  `from_ordering`/`limit` paginate the same way `get_messages/4` and
  `get_relations/7` do: only threads whose latest-activity ordering is
  strictly less than `from_ordering` are returned, so the last returned
  activity ordering makes a valid `from` for the next page. There's no
  `dir` param — "most-recently-active first" is the only order the
  endpoint (`GET /rooms/:room_id/threads`) defines.

  `opts[:participated_user_id]`, if given, restricts to threads where
  that user sent at least one `m.thread`-related child event — again the
  same participation notion `current_user_participated` already computes,
  so the list endpoint and the per-event bundle can't drift apart on what
  "participated" means.

  Returns a list of `{root_event, latest_activity_ordering}` pairs.
  """
  def get_thread_roots(room_id, from_ordering, limit, opts \\ []) do
    participated_user_id = Keyword.get(opts, :participated_user_id)

    activity =
      from(e in Event,
        where:
          e.room_id == ^room_id and not e.rejected and not e.soft_failed and
            fragment("?->'m.relates_to'->>'rel_type'", e.content) == "m.thread",
        group_by: fragment("?->'m.relates_to'->>'event_id'", e.content),
        select: %{
          root_event_id: fragment("?->'m.relates_to'->>'event_id'", e.content),
          latest_ordering: max(e.stream_ordering)
        }
      )

    activity =
      if participated_user_id do
        from(e in activity, having: fragment("bool_or(? = ?)", e.sender, ^participated_user_id))
      else
        activity
      end

    from(a in subquery(activity),
      join: root in Event,
      on: root.event_id == a.root_event_id,
      where: a.latest_ordering < ^from_ordering and not root.rejected and not root.soft_failed,
      order_by: [desc: a.latest_ordering],
      limit: ^limit,
      select: {root, a.latest_ordering}
    )
    |> Repo.all()
  end

  @doc """
  Full-text search over `m.room.message` bodies across `room_ids`
  (for `POST /search`). Returns `{[{event_id, rank}], total_count}`,
  ordered by `order_by` ("rank" or "recent").
  """
  def search_messages(room_ids, search_term, order_by, limit, offset \\ 0)

  def search_messages([], _search_term, _order_by, _limit, _offset), do: {[], 0, nil}

  @doc """
  Full-text search. `offset` (from a prior call's returned next-page
  cursor, round-tripped through `/search`'s `next_batch`) skips the rows
  already returned by earlier pages — plain `OFFSET`, not a keyset cursor,
  since "rank" ordering has no single column to key off (ties are
  expected, and meaningful only relative to the query) the way
  `stream_ordering` would for "recent". Search result pages aren't
  expected to stay stable under concurrent writes to the same degree
  `/messages` pagination is, so the simpler, universally-correct-for-both-
  orderings approach wins here.

  Returns `{[{event_id, rank}], total_count, next_offset | nil}` —
  `next_offset` is set only when this page came back full (there may be
  more), never on the trailing empty page a client fetches to confirm
  the end.
  """
  def search_messages(room_ids, search_term, order_by, limit, offset) do
    order_sql = if order_by == "recent", do: "stream_ordering DESC", else: "rank DESC"

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT event_id, ts_rank(to_tsvector('english', content->>'body'), plainto_tsquery('english', $2)) AS rank
        FROM events
        WHERE room_id = ANY($1) AND type = 'm.room.message' AND NOT rejected
          AND to_tsvector('english', content->>'body') @@ plainto_tsquery('english', $2)
        ORDER BY #{order_sql}
        LIMIT $3 OFFSET $4
        """,
        [room_ids, search_term, limit, offset]
      )

    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT count(*)
        FROM events
        WHERE room_id = ANY($1) AND type = 'm.room.message' AND NOT rejected
          AND to_tsvector('english', content->>'body') @@ plainto_tsquery('english', $2)
        """,
        [room_ids, search_term]
      )

    next_offset = if length(rows) == limit, do: offset + limit

    {Enum.map(rows, fn [event_id, rank] -> {event_id, rank} end), count, next_offset}
  end

  @doc "Returns the current max stream_ordering across all events."
  def current_max_stream_ordering do
    Repo.one(from(e in Event, select: max(e.stream_ordering))) || 0
  end

  @doc "Returns the max stream_ordering in a specific room."
  def room_max_stream_ordering(room_id) do
    Repo.one(
      from(e in Event,
        where: e.room_id == ^room_id,
        select: max(e.stream_ordering)
      )
    ) || 0
  end

  # ---------------------------------------------------------------------------
  # Relations (reactions, threads) — Phase 5
  # ---------------------------------------------------------------------------

  @doc """
  Adds `unsigned.m.relations` bundles (m.annotation chunk, m.thread summary)
  to each event map in `event_maps` that has children, in a single query.

  Spec: https://spec.matrix.org/latest/client-server-api/#event-relationships
  """
  def bundle_relations(room_id, event_maps, opts \\ [])
  def bundle_relations(_room_id, [], _opts), do: []

  def bundle_relations(room_id, event_maps, opts) do
    user_id = Keyword.get(opts, :user_id)
    target_ids = Enum.map(event_maps, & &1["event_id"])

    children_by_target =
      from(e in Event,
        where:
          e.room_id == ^room_id and not e.rejected and not e.soft_failed and
            fragment("?->'m.relates_to'->>'event_id'", e.content) in ^target_ids,
        select: %{
          event_id: e.event_id,
          sender: e.sender,
          type: e.type,
          content: e.content,
          origin_server_ts: e.origin_server_ts,
          stream_ordering: e.stream_ordering,
          target_event_id: fragment("?->'m.relates_to'->>'event_id'", e.content),
          rel_type: fragment("?->'m.relates_to'->>'rel_type'", e.content)
        }
      )
      |> Repo.all()
      |> Enum.group_by(& &1.target_event_id)

    Enum.map(event_maps, fn event_map ->
      case Map.get(children_by_target, event_map["event_id"]) do
        nil -> event_map
        children -> put_relations_bundle(room_id, event_map, children, user_id)
      end
    end)
  end

  @doc "Bundles relations for a single event map (see `bundle_relations/3`)."
  def bundle_relations_one(room_id, event_map, opts \\ []) do
    [bundled] = bundle_relations(room_id, [event_map], opts)
    bundled
  end

  @specially_aggregated_rel_types ["m.annotation", "m.thread"]

  defp put_relations_bundle(room_id, event_map, children, user_id) do
    relations =
      %{}
      |> put_annotation_bundle(children)
      |> put_thread_bundle(room_id, children, user_id)
      |> put_generic_count_bundle(children)

    if relations == %{} do
      event_map
    else
      unsigned = Map.put(event_map["unsigned"] || %{}, "m.relations", relations)
      Map.put(event_map, "unsigned", unsigned)
    end
  end

  defp put_annotation_bundle(relations, children) do
    chunk =
      children
      |> Enum.filter(&(&1.rel_type == "m.annotation"))
      |> Enum.group_by(fn c -> {c.type, get_in(c.content, ["m.relates_to", "key"])} end)
      |> Enum.map(fn {{type, key}, events} ->
        %{"type" => type, "key" => key, "count" => length(events)}
      end)

    if chunk == [], do: relations, else: Map.put(relations, "m.annotation", %{"chunk" => chunk})
  end

  defp put_thread_bundle(relations, room_id, children, user_id) do
    case Enum.filter(children, &(&1.rel_type == "m.thread")) do
      [] ->
        relations

      thread_events ->
        latest = Enum.max_by(thread_events, & &1.stream_ordering)

        latest_event_map = %{
          "event_id" => latest.event_id,
          "room_id" => room_id,
          "sender" => latest.sender,
          "type" => latest.type,
          "content" => latest.content,
          "origin_server_ts" => latest.origin_server_ts
        }

        Map.put(relations, "m.thread", %{
          "latest_event" => latest_event_map,
          "count" => length(thread_events),
          "current_user_participated" =>
            user_id != nil and Enum.any?(thread_events, &(&1.sender == user_id))
        })
    end
  end

  # Spec fallback for relation types without a special aggregation format
  # (e.g. m.reference, used by MSC3381 polls to link responses/end to the
  # poll start event): bundle just a count. Real vote tallying is left to
  # clients, which fetch m.poll.response/m.poll.end via GET .../relations —
  # this matches how Synapse handles polls (no server-side tally).
  defp put_generic_count_bundle(relations, children) do
    children
    |> Enum.reject(&(&1.rel_type in @specially_aggregated_rel_types or is_nil(&1.rel_type)))
    |> Enum.group_by(& &1.rel_type)
    |> Enum.reduce(relations, fn {rel_type, events}, acc ->
      Map.put(acc, rel_type, %{"count" => length(events)})
    end)
  end

  # ---------------------------------------------------------------------------
  # Room state queries
  # ---------------------------------------------------------------------------

  @doc "Returns all current state events for a room as a list of event maps."
  def get_current_state(room_id) do
    Repo.all(
      from(e in Event,
        join: s in "current_room_state",
        on: s.event_id == e.event_id and s.room_id == ^room_id,
        where: not e.rejected,
        select: e
      )
    )
  end

  @doc "Returns the current state event for {room_id, type, state_key}."
  def get_state_event(room_id, type, state_key) do
    result =
      Repo.one(
        from(e in Event,
          join: s in "current_room_state",
          on:
            s.event_id == e.event_id and
              s.room_id == ^room_id and
              s.type == ^type and
              s.state_key == ^state_key,
          where: not e.rejected,
          select: e
        )
      )

    case result do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  @doc "Returns current state as a map of {type, state_key} => event_map for use in auth rules."
  def get_current_state_map(room_id) do
    room_id
    |> get_current_state()
    |> Enum.reduce(%{}, fn event, acc ->
      Map.put(acc, {event.type, event.state_key}, event_to_map(event))
    end)
  end

  @doc """
  Room state *as of* `stream_ordering` — `get_current_state/1`'s
  point-in-time counterpart, generalizing `get_room_members_at/3`'s
  DISTINCT ON pattern (latest row per group, capped by ordering) from
  `m.room.member` alone to every `(type, state_key)` pair. Backs GET
  /rooms/:id/state for a user who has left or been banned (per spec:
  such a request answers with the state as of when they left, not
  current state — see `AxonWeb.EventController.get_state/2`).
  """
  def get_room_state_at(room_id, stream_ordering) do
    Repo.all(
      from(e in Event,
        where:
          e.room_id == ^room_id and not is_nil(e.state_key) and
            e.stream_ordering <= ^stream_ordering and
            not e.rejected and not e.soft_failed,
        order_by: [asc: e.type, asc: e.state_key, desc: e.stream_ordering],
        distinct: [asc: e.type, asc: e.state_key]
      )
    )
  end

  @doc """
  The state event for `{room_id, type, state_key}` *as of* `stream_ordering`
  — `get_state_event/3`'s point-in-time counterpart, same rationale as
  `get_room_state_at/2` but for a single key (backs GET
  /rooms/:id/state/:type/:state_key for a departed member).
  """
  def get_state_event_at(room_id, type, state_key, stream_ordering) do
    result =
      Repo.one(
        from(e in Event,
          where:
            e.room_id == ^room_id and e.type == ^type and e.state_key == ^state_key and
              e.stream_ordering <= ^stream_ordering and
              not e.rejected and not e.soft_failed,
          order_by: [desc: e.stream_ordering],
          limit: 1
        )
      )

    case result do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  # ---------------------------------------------------------------------------
  # Membership queries
  # ---------------------------------------------------------------------------

  def get_joined_rooms(user_id) do
    Repo.all(
      from(m in RoomMembership,
        where: m.user_id == ^user_id and m.membership == "join" and not m.forgotten,
        select: m.room_id
      )
    )
  end

  def get_invited_rooms(user_id) do
    Repo.all(
      from(m in RoomMembership,
        where: m.user_id == ^user_id and m.membership == "invite" and not m.forgotten,
        select: m.room_id
      )
    )
  end

  @doc """
  Returns {room_id => max_stream_ordering} for the given rooms — used by
  sliding sync's `by_recency` list sort. Rooms with no events (shouldn't
  happen in practice, m.room.create always exists) are simply absent.
  """
  def room_recency_map(room_ids) do
    Repo.all(
      from(e in Event,
        where: e.room_id in ^room_ids and not e.rejected,
        group_by: e.room_id,
        select: {e.room_id, max(e.stream_ordering)}
      )
    )
    |> Map.new()
  end

  @doc """
  Last `limit` non-rejected/non-soft-failed events in a room, oldest first,
  visible to `viewer_id` — for sliding sync's per-room timeline. Shadow-ban
  filtering (see get_user_events_since/2) applies the same way; unlike that
  function this isn't scoped to "since a cursor", so a filtered-out event
  isn't backfilled to keep the list at `limit` length.
  """
  def get_recent_room_events(room_id, limit, viewer_id \\ nil) do
    events =
      Repo.all(
        from(e in Event,
          where: e.room_id == ^room_id and not e.rejected and not e.soft_failed,
          order_by: [desc: e.stream_ordering],
          limit: ^limit
        )
      )
      |> Enum.reverse()

    banned_senders = shadow_banned_senders(events)
    Enum.reject(events, &hidden_from_viewer?(&1, viewer_id, banned_senders))
  end

  @doc """
  Records a typing/receipt change for room_id and wakes any long-polling
  /sync for its members immediately, the same way KeyStore.record_device_list_update/1
  does for device-list changes — see /sync's ephemeral section.
  """
  def record_ephemeral_update(room_id) do
    Repo.insert_all("ephemeral_updates", [%{room_id: room_id}])
    Phoenix.PubSub.broadcast(Axon.PubSub, "room:#{room_id}", {:ephemeral, room_id})
  end

  @doc "Server names of this room's joined members who aren't local, for EDU fan-out targeting."
  def remote_servers_for_room(room_id) do
    local_server = Application.get_env(:axon_web, :server_name, "localhost")

    Repo.all(
      from(m in RoomMembership,
        where: m.room_id == ^room_id and m.membership == "join",
        select: m.user_id
      )
    )
    |> Enum.map(&(&1 |> AxonCore.MatrixId.server_name()))
    |> Enum.reject(&(&1 == local_server))
    |> Enum.uniq()
  end

  @doc """
  Server names of users (other than user_id) who share any room with
  user_id, for presence EDU fan-out targeting — presence is federated to
  every server you share a room with, not just the ones for a single room.
  """
  def remote_servers_for_user(user_id) do
    local_server = Application.get_env(:axon_web, :server_name, "localhost")

    Repo.all(
      from(m2 in RoomMembership,
        join: m1 in RoomMembership,
        on: m1.room_id == m2.room_id and m1.user_id == ^user_id and m1.membership == "join",
        where: m2.membership == "join" and m2.user_id != ^user_id,
        select: m2.user_id,
        distinct: true
      )
    )
    |> Enum.map(&(&1 |> AxonCore.MatrixId.server_name()))
    |> Enum.reject(&(&1 == local_server))
    |> Enum.uniq()
  end

  @doc "Returns %{joined: n, invited: n} member counts for a room."
  def member_counts(room_id) do
    counts =
      Repo.all(
        from(m in RoomMembership,
          where: m.room_id == ^room_id and m.membership in ["join", "invite"],
          group_by: m.membership,
          select: {m.membership, count(m.user_id)}
        )
      )
      |> Map.new()

    %{joined: Map.get(counts, "join", 0), invited: Map.get(counts, "invite", 0)}
  end

  @doc "Whether user_id (typically remote) is a joined member of any room we know about."
  def known_user?(user_id) do
    Repo.exists?(
      from(m in RoomMembership, where: m.user_id == ^user_id and m.membership == "join")
    )
  end

  def get_knocked_rooms(user_id) do
    Repo.all(
      from(m in RoomMembership,
        where: m.user_id == ^user_id and m.membership == "knock" and not m.forgotten,
        select: m.room_id
      )
    )
  end

  @preview_state_types ~w(m.room.join_rules m.room.canonical_alias m.room.avatar m.room.name m.room.create m.room.encryption)

  @doc """
  Stripped state events (type/state_key/sender/content only) — the shape
  used for invite_state and knock_state room previews.
  """
  def stripped_state_events(room_id, types \\ @preview_state_types) do
    room_id
    |> get_current_state()
    |> Enum.filter(&(&1.type in types))
    |> Enum.map(fn e ->
      %{
        "type" => e.type,
        "state_key" => e.state_key,
        "sender" => e.sender,
        "content" => e.content || %{}
      }
    end)
  end

  @doc "Persists a knock's room preview (stripped state events) for /sync to render."
  def set_knock_preview_state(room_id, user_id, events) do
    Repo.update_all(
      from(m in "room_memberships",
        where: m.room_id == ^room_id and m.user_id == ^user_id and m.membership == "knock"
      ),
      set: [preview_state: %{"events" => events}]
    )

    :ok
  end

  @doc "Returns the stored knock preview's stripped events for a room the user has knocked on."
  def get_knock_preview_state(room_id, user_id) do
    preview =
      Repo.one(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.user_id == ^user_id and m.membership == "knock",
          select: m.preview_state
        )
      )

    (preview || %{})["events"] || []
  end

  @doc """
  Persists a federated invite's `invite_room_state` preview (per spec: a
  stripped snapshot of some room state the inviting server hands over
  since we have no other way to learn anything about a room we're not
  otherwise resident in) — mirrors set_knock_preview_state/3 exactly.
  """
  def set_invite_preview_state(room_id, user_id, events) do
    Repo.update_all(
      from(m in "room_memberships",
        where: m.room_id == ^room_id and m.user_id == ^user_id and m.membership == "invite"
      ),
      set: [preview_state: %{"events" => events}]
    )

    :ok
  end

  @doc "Returns the stored invite preview's stripped events for a room the user was invited to."
  def get_invite_preview_state(room_id, user_id) do
    preview =
      Repo.one(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.user_id == ^user_id and m.membership == "invite",
          select: m.preview_state
        )
      )

    (preview || %{})["events"] || []
  end

  def get_left_rooms_since(user_id, since_ordering, opts \\ []) do
    exclude_forgotten = Keyword.get(opts, :exclude_forgotten, false)

    q =
      from(m in RoomMembership,
        join: e in Event,
        on: e.event_id == m.event_id,
        where:
          m.user_id == ^user_id and
            m.membership in ["leave", "ban"] and
            e.stream_ordering > ^since_ordering,
        select: m.room_id
      )

    q = if exclude_forgotten, do: from(m in q, where: not m.forgotten), else: q
    Repo.all(q)
  end

  @doc """
  Returns the latest applicable leave/ban stream ordering for each room the
  user has left in this sync window.

  The materialized current membership row is authoritative, and its persisted
  `event_id` supplies the matching stream-ordering cutoff.
  """
  def get_left_room_cutoffs_since(user_id, since_ordering, opts \\ []) do
    exclude_forgotten = Keyword.get(opts, :exclude_forgotten, false)

    query =
      from(m in RoomMembership,
        join: e in Event,
        on: e.event_id == m.event_id,
        where:
          m.user_id == ^user_id and m.membership in ["leave", "ban"] and
            e.stream_ordering > ^since_ordering and not e.rejected and not e.soft_failed,
        select: {m.room_id, e.stream_ordering}
      )

    query = if exclude_forgotten, do: from([m, e] in query, where: not m.forgotten), else: query
    Repo.all(query) |> Map.new()
  end

  def get_room_members(room_id, memberships \\ ["join"]) do
    Repo.all(
      from(m in RoomMembership,
        where: m.room_id == ^room_id and m.membership in ^memberships,
        select: m
      )
    )
  end

  @doc """
  Room membership *as of* `stream_ordering` — the state a `GET
  .../members?at=<token>` request from a client actually asks for (`at`
  decodes to a stream_ordering boundary — see
  `AxonWeb.SyncHelpers.parse_token/1`), as opposed to `get_room_members/2`,
  which only ever answers with current, live membership.

  `room_memberships` is a materialized *current*-state table with no
  history — it's overwritten in place on every membership change, so it
  structurally cannot answer this. Every event is kept forever, though
  (append-only), so this is a real point-in-time query rather than an
  approximation: for each user, the latest `m.room.member` event with
  `stream_ordering <= boundary` — the same "current state, but as of an
  earlier stream position" computation current_room_state itself would
  have held at that moment. `DISTINCT ON` (via `distinct: [asc: ...]`
  paired with a matching `order_by` prefix) is the direct Postgres
  idiom for "latest row per group," not a full-room state resolution
  replay — cheap enough to run per-request rather than needing its own
  materialized history the way Synapse's `state_groups` do.
  """
  def get_room_members_at(room_id, stream_ordering, memberships \\ ["join"]) do
    Repo.all(
      from(e in Event,
        where:
          e.room_id == ^room_id and e.type == "m.room.member" and
            not is_nil(e.state_key) and
            e.stream_ordering <= ^stream_ordering and
            not e.rejected and not e.soft_failed,
        order_by: [asc: e.state_key, desc: e.stream_ordering],
        distinct: [asc: e.state_key]
      )
    )
    |> Enum.filter(&(Map.get(&1.content, "membership") in memberships))
  end

  def get_membership(room_id, user_id) do
    case Repo.get_by(RoomMembership, room_id: room_id, user_id: user_id) do
      nil -> {:ok, nil}
      m -> {:ok, m.membership}
    end
  end

  # ---------------------------------------------------------------------------
  # Snapshots
  # ---------------------------------------------------------------------------

  def latest_snapshot(room_id) do
    Repo.one(
      from(s in "room_state_snapshots",
        where: s.room_id == ^room_id,
        order_by: [desc: s.after_stream_ordering],
        limit: 1,
        select: %{
          after_stream_ordering: s.after_stream_ordering,
          state_map: s.state_map
        }
      )
    )
  end

  def create_snapshot(room_id, after_stream_ordering, state_map) do
    # state_map is a map with string keys "{type}\0{state_key}" => event_id
    Repo.insert_all("room_state_snapshots", [
      %{
        room_id: room_id,
        after_stream_ordering: after_stream_ordering,
        state_map: state_map,
        inserted_at: DateTime.utc_now(:microsecond)
      }
    ])

    :ok
  end

  # ---------------------------------------------------------------------------
  # Sync helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns all events for rooms the user is in, since the given stream_ordering.
  Groups results by room_id.
  """
  def get_user_events_since(user_id, since_ordering) do
    get_sync_snapshot(user_id, since_ordering,
      include_left: false,
      include_new_left: true,
      exclude_forgotten: false
    ).events_by_room
  end

  @doc """
  Reads the room membership view and its bounded sync events from one
  repeatable-read database snapshot.

  `include_left` controls historical leave rooms, `include_new_left` controls
  leaves newer than the supplied token, and `exclude_forgotten` controls whether
  forgotten leave rooms are omitted.

  This public snapshot API owns its transaction and must not be called from an
  existing application transaction.
  """
  def get_sync_snapshot(user_id, since_ordering, opts \\ []) do
    include_left = Keyword.get(opts, :include_left, true)
    include_new_left = Keyword.get(opts, :include_new_left, true)
    exclude_forgotten = Keyword.get(opts, :exclude_forgotten, true)
    after_memberships = Keyword.get(opts, :after_memberships, fn _left_cutoffs -> :ok end)

    snapshot_transaction(fn ->
      memberships =
        Repo.all(
          from(m in RoomMembership,
            join: e in Event,
            on: e.event_id == m.event_id,
            where:
              m.user_id == ^user_id and not e.rejected and not e.soft_failed and
                m.membership in ["join", "leave", "ban"],
            select: %{
              room_id: m.room_id,
              membership: m.membership,
              forgotten: m.forgotten,
              stream_ordering: e.stream_ordering
            }
          )
        )

      joined_rooms =
        for %{membership: "join", forgotten: false, room_id: room_id} <- memberships,
            do: room_id

      left_cutoffs =
        memberships
        |> Enum.filter(fn membership ->
          membership.membership in ["leave", "ban"] and
            (not exclude_forgotten or not membership.forgotten) and
            (include_left or
               (include_new_left and membership.stream_ordering > since_ordering))
        end)
        |> Map.new(&{&1.room_id, &1.stream_ordering})

      after_memberships.(left_cutoffs)

      events = get_bounded_sync_events(joined_rooms, left_cutoffs, since_ordering)
      banned_senders = shadow_banned_senders(events)

      events_by_room =
        events
        |> Enum.reject(&hidden_from_viewer?(&1, user_id, banned_senders))
        |> Enum.group_by(& &1.room_id)

      %{
        joined_rooms: joined_rooms,
        left_cutoffs: left_cutoffs,
        events_by_room: events_by_room
      }
    end)
  end

  defp get_bounded_sync_events(joined_rooms, left_cutoffs, since_ordering) do
    if joined_rooms == [] and map_size(left_cutoffs) == 0 do
      []
    else
      Repo.all(bounded_sync_events_query(joined_rooms, left_cutoffs, since_ordering))
    end
  end

  @doc false
  def bounded_sync_events_query(joined_rooms, left_cutoffs, since_ordering) do
    {left_room_ids, left_room_cutoffs} = left_cutoffs |> Enum.sort() |> Enum.unzip()
    max_ordering = 9_223_372_036_854_775_807
    room_ids = joined_rooms ++ left_room_ids
    cutoffs = List.duplicate(max_ordering, length(joined_rooms)) ++ left_room_cutoffs

    from(e in Event,
      join:
        bound in fragment(
          "SELECT * FROM unnest(?::text[], ?::bigint[]) AS sync_bound(room_id, cutoff)",
          ^room_ids,
          ^cutoffs
        ),
      on:
        e.room_id == field(bound, :room_id) and
          e.stream_ordering <= field(bound, :cutoff),
      where: e.stream_ordering > ^since_ordering and not e.rejected and not e.soft_failed,
      order_by: [asc: e.stream_ordering]
    )
  end

  @doc false
  def snapshot_transaction(fun, opts \\ []) when is_function(fun, 0) do
    repo = Keyword.get(opts, :repo, Repo)

    if repo.in_transaction?() do
      raise ArgumentError,
            "get_sync_snapshot must not be called inside an existing application transaction"
    end

    set_isolation? =
      repo != Repo or Application.get_env(:axon_core, :snapshot_set_transaction_isolation, true)

    case repo.transaction(fn ->
           if set_isolation? do
             Ecto.Adapters.SQL.query!(
               repo,
               "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ",
               []
             )
           end

           fun.()
         end) do
      {:ok, result} -> result
      {:error, reason} -> raise "snapshot transaction rolled back: #{inspect(reason)}"
    end
  end

  # Shadow-ban local enforcement (admin API): a shadow-banned sender's own
  # non-state (message-like) events are hidden from every *other* local
  # viewer's sync — the whole point is they don't find out — but never from
  # themselves (reading your own writes must always work normally) and
  # never for state events (hiding e.g. a join would corrupt every other
  # viewer's picture of room membership, a much bigger inconsistency than
  # muting a spammer's messages). The outbound federation half of this
  # lives in AxonRoom.RoomProcess.shadow_banned_message?/1.
  defp hidden_from_viewer?(%Event{state_key: nil, sender: sender}, viewer_id, banned_senders)
       when sender != viewer_id do
    MapSet.member?(banned_senders, sender)
  end

  defp hidden_from_viewer?(_event, _viewer_id, _banned_senders), do: false

  defp shadow_banned_senders(events) do
    senders = events |> Enum.map(& &1.sender) |> Enum.uniq()

    if senders == [] do
      MapSet.new()
    else
      Repo.all(
        from(u in "users",
          where: u.user_id in ^senders and u.shadow_banned == true,
          select: u.user_id
        )
      )
      |> MapSet.new()
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Converts an Event schema struct to a **client-facing** event map — the
  shape the Client-Server API returns (`/sync`, `/messages`, `/state`,
  `/event/:id`, `/context`, search results). Always carries `room_id`,
  including on a room-v12 `m.room.create` event: only the *federation*
  PDU format omits it there (see `event_to_pdu/1`), and the CS API's
  ClientEvent schema requires it unconditionally.
  """
  def event_to_map(%Event{} = e) do
    base_event_map(e)
    |> maybe_put("state_key", e.state_key)
    |> maybe_put("unsigned", e.unsigned)
  end

  def event_to_map(m) when is_map(m), do: m

  @doc """
  Converts an Event schema struct to a **federation PDU** map — the shape
  that goes out over the server-server API (`/send`, `send_join` state,
  `/state`, `/backfill`, `/get_missing_events`, `/event`, `/event_auth`).

  Identical to `event_to_map/1` except that a room-v12 `m.room.create`
  event's `room_id` is omitted: per the v12 PDU schema ("room_id ...
  Omitted from m.room.create events") the room ID *is* that event's own
  reference hash with `!` for `$`, so the field is redundant on the wire —
  and, critically, its presence would change the event's content hash, so
  a receiving server would compute a different event ID and reject it.

  This distinction used to not exist: `event_to_map/1` stripped `room_id`
  unconditionally and was the single function both APIs went through, so
  every *client*-facing view of a v12 create event was missing its
  `room_id` too (Complement's
  TestMSC4291RoomIDAsHashOfCreateEvent_RoomIDIsOnCreateEvent asserts
  exactly this across `/state`, `/messages`, `/event/{id}`, `/context`
  and `/state?format=event`).
  """
  def event_to_pdu(%Event{} = e) do
    base = base_event_map(e)

    base =
      if e.type == "m.room.create" and e.room_version == "12",
        do: Map.delete(base, "room_id"),
        else: base

    base
    |> maybe_put("state_key", e.state_key)
    |> maybe_put("unsigned", e.unsigned)
  end

  def event_to_pdu(m) when is_map(m), do: m

  defp base_event_map(%Event{} = e) do
    %{
      "event_id" => e.event_id,
      "room_id" => e.room_id,
      "sender" => e.sender,
      "type" => e.type,
      "content" => e.content || %{},
      "origin_server_ts" => e.origin_server_ts,
      "origin" => e.origin,
      "depth" => e.depth,
      "auth_events" => e.auth_event_ids,
      "prev_events" => e.prev_event_ids,
      "signatures" => e.signatures,
      "hashes" => e.hashes
    }
  end

  @doc "Returns true if the room exists locally."
  def room_exists?(room_id) do
    import Ecto.Query
    Repo.one(from(r in "rooms", where: r.room_id == ^room_id, select: r.room_id)) != nil
  end

  @doc "Fetch event by ID and convert to federation PDU format (its only caller is send_join)."
  def event_to_pdu_by_id(event_id) do
    case get_event(event_id) do
      {:ok, e} -> event_to_pdu(e)
      _ -> nil
    end
  end

  @doc "Fetch an event map by ID for use in state resolution auth chain traversal."
  def get_event_map(event_id) do
    case get_event(event_id) do
      {:ok, e} -> event_to_map(e)
      _ -> nil
    end
  end

  @doc """
  Bulk fetch: `%{event_id => event_map}` for every id in `event_ids` found
  locally (unknown ids are simply absent, not an error) — one round trip
  instead of one query per id. For use by `AxonRoom.StateResolver`'s
  level-by-level ancestor walk.
  """
  def get_event_maps([]), do: %{}

  def get_event_maps(event_ids) do
    Repo.all(from(e in Event, where: e.event_id in ^event_ids))
    |> Map.new(fn e -> {e.event_id, event_to_map(e)} end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
