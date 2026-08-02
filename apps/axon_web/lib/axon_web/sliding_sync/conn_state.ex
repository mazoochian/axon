defmodule AxonWeb.SlidingSync.ConnState do
  @moduledoc """
  Per-`conn_id` sliding sync (MSC4186) session state — what lets the
  controller stop re-sending a full `SYNC` op for a list range, or a room's
  full entry, when nothing in it actually changed since the last response
  on the same connection.

  MSC4186 scopes this bandwidth optimization to an explicit, client-chosen
  `conn_id` (distinguishing e.g. multiple browser tabs polling the same
  device concurrently): a request with no `conn_id` (or an empty one) gets
  today's behavior unchanged — full `SYNC` every range, every room resent
  every response — since there's nothing to key state off. Only a client
  that opts in by sending the same `conn_id` on every request benefits.

  In-memory (ETS) and TTL-swept, matching AxonSync.Typing/Presence's
  approach: this is a bandwidth cache, not durable state — losing it after
  a restart (or a period of client inactivity) just means the next
  response for that conn_id falls back to a full resync, which is always a
  spec-valid response.

  State per `{user_id, device_id, conn_id}`:
    * `lists` — `%{{list_key, range} => room_ids}` for the room_ids last
      actually sent (as a `SYNC` op) for that exact range of that list.
    * `rooms` — `%{room_id => fingerprint}` for the content last actually
      sent for that room (see `AxonWeb.SlidingSyncController`'s
      `room_fingerprint/1`), regardless of which list/subscription surfaced it.
  """

  use GenServer

  @table :axon_sliding_sync_conn_state
  @tick_interval :timer.seconds(60)
  # A conn_id with no requests for this long is dropped — the client either
  # went away or will get a (spec-valid) full resync on its next request.
  @ttl_ms :timer.minutes(10)

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Returns the stored state for this connection, or empty defaults if none/expired."
  def get(user_id, device_id, conn_id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, {user_id, device_id, conn_id}) do
      [{_key, %{lists: lists, rooms: rooms}, expires_at}] when expires_at > now ->
        %{lists: lists, rooms: rooms}

      _ ->
        %{lists: %{}, rooms: %{}}
    end
  end

  @doc "Replaces the stored state for this connection, resetting its TTL."
  def put(user_id, device_id, conn_id, %{lists: _, rooms: _} = state) do
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {{user_id, device_id, conn_id}, state, expires_at})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init([]) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    Process.send_after(self(), :tick, @tick_interval)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, state}
  end
end
