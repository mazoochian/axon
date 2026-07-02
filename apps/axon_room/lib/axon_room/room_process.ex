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
  alias AxonRoom.{AuthRules, EventBuilder, StateApplicator}

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
  Sends an event through the room. Checks auth rules, persists, broadcasts.

  Returns `{:ok, event_id}` or `{:error, reason}`.
  """
  def send_event(room_id, sender, type, content, opts \\ []) do
    with {:ok, pid} <- get_or_start(room_id) do
      GenServer.call(pid, {:send_event, sender, type, content, opts}, 30_000)
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

    event = EventBuilder.build(sender, type, content, room_ctx, opts)

    case AuthRules.check(event, state.current_state, state.room_version) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :ok ->
        case EventStore.insert_event(event, state.room_version) do
          {:ok, persisted} ->
            event_map = EventStore.event_to_map(persisted)
            new_state = apply_and_advance(state, event_map, persisted.stream_ordering)
            broadcast(state.room_id, event_map)
            broadcast_for_federation(state.room_id, event_map, new_state.current_state)
            {:reply, {:ok, event["event_id"]}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
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

  defp save_snapshot(state, stream_ordering) do
    state_map =
      Enum.into(state.current_state, %{}, fn {{type, sk}, event} ->
        {"#{type}\0#{sk}", event["event_id"]}
      end)

    EventStore.create_snapshot(state.room_id, stream_ordering, state_map)
  end

  defp deserialize_snapshot(state_map, room_id) do
    # state_map: %{"type\0state_key" => event_id}
    # We need to load the actual events from the DB
    event_ids = Map.values(state_map)

    events =
      if event_ids == [] do
        []
      else
        import Ecto.Query

        AxonCore.Repo.all(
          from e in AxonCore.Schema.Event,
            where: e.event_id in ^event_ids and e.room_id == ^room_id
        )
      end

    event_map_by_id =
      Enum.into(events, %{}, fn e ->
        {e.event_id, EventStore.event_to_map(e)}
      end)

    Enum.into(state_map, %{}, fn {key, event_id} ->
      [type, state_key] = String.split(key, "\0", parts: 2)
      event = Map.get(event_map_by_id, event_id)
      {{type, state_key}, event}
    end)
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp broadcast(room_id, event_map) do
    Phoenix.PubSub.broadcast(@pubsub, "room:#{room_id}", {:new_event, room_id, event_map})
  end

  # Broadcast for federation fan-out via PubSub. axon_web subscribes and sends
  # the event to remote servers. This avoids a cross-app dependency from
  # axon_room to axon_federation (they're at the same supervision level).
  defp broadcast_for_federation(_room_id, event_map, current_state) do
    local_server = Application.get_env(:axon_web, :server_name, "localhost")

    remote_servers =
      current_state
      |> Enum.flat_map(fn
        {{"m.room.member", user_id}, event} ->
          membership = get_in(event, ["content", "membership"])
          server = user_id |> String.split(":") |> List.last()
          if membership == "join" and server != local_server, do: [server], else: []

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
