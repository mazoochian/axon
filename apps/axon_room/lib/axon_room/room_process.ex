defmodule AxonRoom.RoomProcess do
  @moduledoc """
  Per-room GenServer. One process per active room, distributed across the cluster
  via Horde.DynamicSupervisor + Horde.Registry.

  Owns current room state in memory. Serializes all mutations. Persists via
  AxonCore.EventStore. Broadcasts new events via Phoenix.PubSub.

  On crash, the supervisor restarts it and it reloads from the latest DB snapshot.
  """

  use GenServer, restart: :transient
  require Logger

  alias AxonCore.EventStore
  alias AxonRoom.{AuthRules, EventBuilder, StateApplicator, StateResolver}

  @snapshot_interval 100
  @pubsub Axon.PubSub

  defstruct [
    :room_id,
    :room_version,
    :last_event_id,
    :depth,
    :snapshot_counter,
    current_state: %{}
  ]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(room_id) do
    GenServer.start_link(__MODULE__, room_id, name: via(room_id))
  end

  def child_spec(room_id) do
    %{
      id: {__MODULE__, room_id},
      start: {__MODULE__, :start_link, [room_id]},
      restart: :transient
    }
  end

  @doc "Gets or starts the RoomProcess for room_id. Returns {:ok, pid}."
  def get_or_start(room_id) do
    case Horde.Registry.lookup(AxonRoom.Registry, room_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case Horde.DynamicSupervisor.start_child(AxonRoom.Supervisor, {__MODULE__, room_id}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  @doc """
  Terminates a room's live process, if running, without touching its DB
  rows — used by admin room purge (AxonCore.EventStore.purge_room/1) so a
  process that's already resident in memory doesn't keep serving stale
  state after its underlying rows are deleted out from under it.
  """
  def stop_if_running(room_id) do
    case Horde.Registry.lookup(AxonRoom.Registry, room_id) do
      [{pid, _}] -> Horde.DynamicSupervisor.terminate_child(AxonRoom.Supervisor, pid)
      [] -> :ok
    end
  end

  @doc """
  Sends an event through the room. Checks auth rules, persists, broadcasts.

  Returns `{:ok, event_id}` or `{:error, reason}`.
  """
  def send_event(room_id, sender, type, content, opts \\ []) do
    with {:ok, pid} <- get_or_start(room_id) do
      GenServer.call(pid, {:send_event, sender, type, content, opts}, 30_000)
    end
  end

  @doc """
  Applies an inbound federation PDU for a room this server already
  participates in. Runs auth check against the room's live in-memory state
  (serialized through this GenServer, same as local sends), persists,
  updates in-memory state, and fans the event out to local `/sync` clients.

  By default this does NOT relay the event on to this room's other
  federated peers — for an ordinary `/send` transaction PDU, the sending
  server already pushed it to every resident server itself, so relaying it
  further would just be duplicate traffic (and risks amplifying loops once
  more than two servers are in a room).

  `opts[:relay_exclude]`, if set, flips that: after applying, the event is
  *also* fanned out to every other server with a joined member in the room
  (excluding the given server name). This is specifically for
  `send_join`/`send_leave`/`send_knock` — the one case where the acting
  user's own server structurally *can't* do this fan-out itself, since it
  only just learned the room's full membership from this same request and
  has no other server to tell but the one resident server it went
  through. That resident server is the only one positioned to relay the
  new event on to everyone else — without this, a room with 3+ servers
  never converges on membership beyond the resident server's own view
  (each newly-joined/knocked/left server's peers never learn about it).
  `relay_exclude` is normally the acting user's own server (already has
  the event — it built and signed it).
  """
  def apply_remote_event(room_id, pdu, opts \\ []) do
    with {:ok, pid} <- get_or_start(room_id) do
      GenServer.call(pid, {:apply_remote_event, pdu, opts}, 30_000)
    end
  end

  @doc "Gets the current full state of the room (list of event maps)."
  def get_state(room_id) do
    with {:ok, pid} <- get_or_start(room_id) do
      GenServer.call(pid, :get_state)
    end
  end

  @doc "Gets a single state event from in-memory state."
  def get_state_event(room_id, type, state_key) do
    with {:ok, pid} <- get_or_start(room_id) do
      GenServer.call(pid, {:get_state_event, type, state_key})
    end
  end

  @doc "Returns current {last_event_id, depth}."
  def get_position(room_id) do
    with {:ok, pid} <- get_or_start(room_id) do
      GenServer.call(pid, :get_position)
    end
  end

  @doc "Returns the full room context map (for federation use)."
  def get_room_ctx(room_id) do
    with {:ok, pid} <- get_or_start(room_id) do
      GenServer.call(pid, :get_room_ctx)
    end
  end

  @doc "Returns current_state as a flat map of {type, state_key} => event_map."
  def get_state_map(room_id) do
    with {:ok, pid} <- get_or_start(room_id) do
      GenServer.call(pid, :get_state_map)
    end
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(room_id) do
    Logger.debug("RoomProcess starting for #{room_id}")

    case load_room(room_id) do
      {:ok, state} ->
        {:ok, state}

      {:error, :not_found} ->
        # Room doesn't exist in DB yet — caller must create it first.
        {:stop, :room_not_found}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_event, sender, type, content, opts}, _from, state) do
    room_ctx = %{
      room_id: state.room_id,
      room_version: state.room_version,
      current_state: state.current_state,
      last_event_id: state.last_event_id,
      depth: state.depth
    }

    event =
      EventBuilder.build(sender, type, content, room_ctx, opts)
      |> with_prev_content(Keyword.get(opts, :state_key), state.current_state)

    case AuthRules.check(event, state.current_state, state.room_version) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :ok ->
        case EventStore.insert_event(event, state.room_version) do
          {:ok, persisted} ->
            event_map = EventStore.event_to_map(persisted)
            new_state = apply_and_advance(state, event_map, persisted.stream_ordering)
            broadcast(state.room_id, event_map)

            unless shadow_banned_message?(event_map) do
              # Federation gets the PDU form, not the client form — they
              # differ for a room-v12 create event (see
              # EventStore.event_to_pdu/1). Only reachable in practice for
              # a create event via a room upgrade, since a brand-new room
              # has no remote members yet, but deriving it explicitly beats
              # relying on that.
              broadcast_for_federation(
                state.room_id,
                EventStore.event_to_pdu(persisted),
                new_state.current_state
              )
            end

            # Push notifications (fire-and-forget)
            AxonPush.Dispatcher.dispatch_event(event_map, state.room_id)
            # AppService fanout via PubSub (avoids circular dep on axon_web)
            Phoenix.PubSub.broadcast(
              @pubsub,
              "all_events",
              {:new_event, state.room_id, event_map}
            )

            {:reply, {:ok, event["event_id"]}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:apply_remote_event, pdu, opts}, _from, state) do
    pdu = with_prev_content(pdu, pdu["state_key"], state.current_state)
    auth_event_ids = pdu["auth_events"] || []

    cond do
      # Transitive rejection: per spec, an event whose auth_events list
      # references an already-rejected event must itself be rejected,
      # regardless of what AuthRules.check would otherwise say (it never
      # looks at auth_events at all — see AuthRules.check/3 for why that's
      # a separate, larger gap this doesn't attempt to close). Checked
      # before state resolution since it's cheap and, when it fires, makes
      # the resolution walk below entirely moot.
      EventStore.any_rejected?(auth_event_ids) ->
        reject_and_persist(pdu, state, :auth_event_rejected)

      true ->
        needs_resolution? = StateResolver.needs_resolution?(pdu, state.last_event_id)

        # When pdu forks away from our head, `resolved_state` isn't just a
        # disposable auth-check scratch value (that's all it was before
        # AxonRoom.StateResolver did real DAG replay) — it's the room's actual
        # correctly-resolved state as of this event's ancestry, and becomes the
        # new `current_state` going forward too (see the rebase below), not
        # just what gates AuthRules.check. Without this, current_state after a
        # fork was whatever the old event happened to blindly overlay onto —
        # effectively last-write-wins by local insertion order, not state
        # resolution.
        resolution =
          if needs_resolution? do
            StateResolver.resolve_for_auth_check(
              pdu,
              state.current_state,
              state.last_event_id,
              state.room_version
            )
          else
            {:ok, state.current_state}
          end

        case resolution do
          # One of pdu's own prev_events couldn't be resolved (unknown
          # locally, even after AxonFederation.Backfill had a chance to
          # close the gap before this call). We cannot prove this event is
          # authorized against its real ancestry, so refuse rather than
          # guess by auth-checking against unrelated current state — see
          # AxonRoom.StateResolver's moduledoc.
          :unresolvable ->
            reject_and_persist(pdu, state, :unknown_ancestor)

          {:ok, resolved_state} ->
            forked? = needs_resolution?

            case AuthRules.check(pdu, resolved_state, state.room_version) do
              {:error, reason} ->
                reject_and_persist(pdu, state, reason)

              :ok ->
                case EventStore.insert_event(pdu, state.room_version) do
                  {:ok, persisted} ->
                    event_map = EventStore.event_to_map(persisted)

                    base_state =
                      if forked?, do: %{state | current_state: resolved_state}, else: state

                    new_state =
                      apply_and_advance(base_state, event_map, persisted.stream_ordering)

                    # Fan out to local /sync clients. Not re-broadcast to federation
                    # by default: for an ordinary /send transaction PDU, the origin
                    # server already pushed it to every other resident server
                    # itself (relaying it further here would just duplicate that).
                    # See apply_remote_event/3's doc for the send_join/leave/knock
                    # exception, opted into via opts[:relay_exclude].
                    broadcast(state.room_id, event_map)

                    case Keyword.get(opts, :relay_exclude, :no_relay) do
                      :no_relay ->
                        :ok

                      exclude ->
                        # PDU form, not client form — see the sibling call in
                        # handle_call({:send_event, ...}) above.
                        broadcast_for_federation(
                          state.room_id,
                          EventStore.event_to_pdu(persisted),
                          new_state.current_state,
                          exclude
                        )
                    end

                    AxonPush.Dispatcher.dispatch_event(event_map, state.room_id)

                    Phoenix.PubSub.broadcast(
                      @pubsub,
                      "all_events",
                      {:new_event, state.room_id, event_map}
                    )

                    {:reply, {:ok, event_map["event_id"]}, new_state}

                  {:error, reason} ->
                    {:reply, {:error, reason}, state}
                end
            end
        end
    end
  end

  def handle_call(:get_state, _from, state) do
    events = Map.values(state.current_state)
    {:reply, {:ok, events}, state}
  end

  def handle_call({:get_state_event, type, state_key}, _from, state) do
    result = Map.get(state.current_state, {type, state_key})
    {:reply, result, state}
  end

  def handle_call(:get_position, _from, state) do
    {:reply, {state.last_event_id, state.depth}, state}
  end

  def handle_call(:get_room_ctx, _from, state) do
    ctx = %{
      room_id: state.room_id,
      room_version: state.room_version,
      last_event_id: state.last_event_id,
      depth: state.depth,
      current_state: state.current_state
    }

    {:reply, ctx, state}
  end

  def handle_call(:get_state_map, _from, state) do
    {:reply, state.current_state, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Persists `pdu` as **rejected**: stored (so GET /event/{id}, /event_auth,
  # and a later "unreject" via EventStore.insert_event/2 all still work) but
  # never applied — no current_state/current_room_state/room_memberships
  # change, no advance of last_event_id/depth, no /sync broadcast, no push,
  # no federation relay. Spec: a rejected event is not applied to room
  # state, not returned by /state or /state_ids or state resolution, and
  # not sent to clients. `state` (the GenServer state) is returned
  # unchanged — this event never becomes part of this room's live view.
  defp reject_and_persist(pdu, state, reason) do
    case EventStore.insert_rejected_event(pdu, state.room_version) do
      {:ok, _persisted} ->
        Logger.debug("Rejected PDU #{pdu["event_id"]} in #{state.room_id}: #{inspect(reason)}")

      {:error, insert_reason} ->
        Logger.warning(
          "Failed to persist rejected PDU #{pdu["event_id"]} in #{state.room_id}: " <>
            "#{inspect(insert_reason)} (original rejection reason: #{inspect(reason)})"
        )
    end

    {:reply, {:error, reason}, state}
  end

  defp load_room(room_id) do
    case EventStore.get_room(room_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, room} ->
        state = %__MODULE__{
          room_id: room_id,
          room_version: room.version,
          depth: -1,
          snapshot_counter: 0
        }

        state = load_from_snapshot(state)
        {:ok, state}
    end
  end

  defp load_from_snapshot(%__MODULE__{room_id: room_id} = state) do
    case EventStore.latest_snapshot(room_id) do
      nil ->
        # No snapshot — replay all events from the beginning
        replay_events(state, 0)

      %{after_stream_ordering: snap_ord, state_map: state_map} ->
        # Restore state from snapshot, then replay newer events
        current_state = deserialize_snapshot(state_map, room_id)
        state = %{state | current_state: current_state}
        replay_events(state, snap_ord)
    end
  end

  defp replay_events(%__MODULE__{room_id: room_id} = state, since_ordering) do
    events = EventStore.get_events_since(room_id, since_ordering, 10_000)

    Enum.reduce(events, state, fn event, acc ->
      event_map = EventStore.event_to_map(event)
      apply_and_advance(acc, event_map, event.stream_ordering)
    end)
  end

  defp apply_and_advance(state, event_map, stream_ordering) do
    new_current_state = StateApplicator.apply(event_map, state.current_state)
    counter = state.snapshot_counter + 1

    new_state = %{
      state
      | current_state: new_current_state,
        last_event_id: event_map["event_id"],
        depth: event_map["depth"],
        snapshot_counter: counter
    }

    if counter >= @snapshot_interval do
      Task.Supervisor.start_child(AxonRoom.TaskSupervisor, fn ->
        save_snapshot(new_state, stream_ordering)
      end)

      %{new_state | snapshot_counter: 0}
    else
      new_state
    end
  end

  # Spec: unsigned.prev_content carries the content of the state event being
  # replaced (MSC3442). Without it, clients can't distinguish a genuine join
  # from a profile-only update (same membership, new displayname/avatar_url)
  # and fall back to rendering "<name> joined the room" on every change.
  defp with_prev_content(event, nil, _current_state), do: event

  defp with_prev_content(event, state_key, current_state) do
    case Map.get(current_state, {event["type"], state_key}) do
      %{"content" => prev_content} ->
        unsigned = Map.put(event["unsigned"] || %{}, "prev_content", prev_content)
        Map.put(event, "unsigned", unsigned)

      _ ->
        event
    end
  end

  # Separates type/state_key in the flattened snapshot map key. NOT a literal
  # NUL byte (\x00) -- Postgres's `jsonb` type rejects it outright
  # ("unsupported Unicode escape sequence"), which silently broke every
  # snapshot write (the fire-and-forget save task just failed and logged, so
  # RoomProcess always replayed from event 0 on restart). \x1F (Unit
  # Separator) is a control character meant for exactly this and, unlike
  # \x00, Postgres stores it fine; Matrix type/state_key strings never
  # contain it.
  @snapshot_key_sep "\x1F"

  defp save_snapshot(state, stream_ordering) do
    state_map =
      Enum.into(state.current_state, %{}, fn {{type, sk}, event} ->
        {"#{type}#{@snapshot_key_sep}#{sk}", event["event_id"]}
      end)

    EventStore.create_snapshot(state.room_id, stream_ordering, state_map)
  end

  defp deserialize_snapshot(state_map, room_id) do
    # state_map: %{"type<sep>state_key" => event_id}
    # We need to load the actual events from the DB
    event_ids = Map.values(state_map)

    events =
      if event_ids == [] do
        []
      else
        import Ecto.Query

        AxonCore.Repo.all(
          from(e in AxonCore.Schema.Event,
            where: e.event_id in ^event_ids and e.room_id == ^room_id
          )
        )
      end

    event_map_by_id =
      Enum.into(events, %{}, fn e ->
        {e.event_id, EventStore.event_to_map(e)}
      end)

    Enum.into(state_map, %{}, fn {key, event_id} ->
      [type, state_key] = String.split(key, @snapshot_key_sep, parts: 2)
      event = Map.get(event_map_by_id, event_id)
      {{type, state_key}, event}
    end)
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp broadcast(room_id, event_map) do
    Phoenix.PubSub.broadcast(@pubsub, "room:#{room_id}", {:new_event, room_id, event_map})
  end

  # Shadow-banned users (admin API) get a normal 200 for every send — they
  # don't get to find out — but their non-state (message-like) events must
  # not actually reach anyone else. State events (joins, etc.) still
  # federate normally: hiding those would corrupt other servers' view of
  # room membership/state, which is a much bigger inconsistency than muting
  # a spammer's messages. Local-side muting (excluding these events from
  # other local users' /sync) happens in AxonCore.EventStore.get_user_events_since/2.
  defp shadow_banned_message?(%{"state_key" => _}), do: false

  defp shadow_banned_message?(event_map) do
    AxonCore.UserStore.shadow_banned?(event_map["sender"])
  end

  # Broadcast for federation fan-out via PubSub. axon_web subscribes and sends
  # the event to remote servers. This avoids a cross-app dependency from
  # axon_room to axon_federation (they're at the same supervision level).
  # `exclude`, when set, drops one server name from the fan-out target
  # list — used by the send_join/leave/knock relay case to skip sending
  # the event straight back to the server that just gave it to us.
  defp broadcast_for_federation(_room_id, event_map, current_state, exclude \\ nil) do
    local_server = Application.get_env(:axon_web, :server_name, "localhost")

    remote_servers =
      current_state
      |> Enum.flat_map(fn
        {{"m.room.member", user_id}, event} ->
          membership = get_in(event, ["content", "membership"])
          server = user_id |> AxonCore.MatrixId.server_name()

          if membership == "join" and server != local_server and server != exclude,
            do: [server],
            else: []

        _ ->
          []
      end)
      |> Enum.uniq()

    if remote_servers != [] do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "federation:fanout",
        {:federate_event, event_map, remote_servers}
      )
    end
  end

  defp via(room_id), do: {:via, Horde.Registry, {AxonRoom.Registry, room_id}}
end
