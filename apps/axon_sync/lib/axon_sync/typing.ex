defmodule AxonSync.Typing do
  @moduledoc """
  Typing-notification state. In-memory (ETS) and auto-expiring, matching
  AxonSync.Presence's approach — typing is ephemeral by spec, so a client's
  `timeout` window is exactly the semantics wanted (no persistence, no
  history), and a restart resetting everyone to "not typing" is correct.

  State: a `:set` table of `{room_id, user_id} => expires_at_ms`. A periodic
  sweep deletes expired entries so a client that disconnects without
  sending `"typing": false` doesn't leave a stale "is typing" forever.
  """

  use GenServer

  @table :axon_typing
  @tick_interval :timer.seconds(5)
  # Guards against a misbehaving/malicious client claiming to type for hours.
  @max_timeout_ms :timer.seconds(120)

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Marks user_id as typing in room_id until timeout_ms from now (capped at 120s)."
  def start(room_id, user_id, timeout_ms) do
    expires_at = System.system_time(:millisecond) + min(timeout_ms, @max_timeout_ms)
    :ets.insert(@table, {{room_id, user_id}, expires_at})
    :ok
  end

  @doc "Marks user_id as no longer typing in room_id."
  def stop(room_id, user_id) do
    :ets.delete(@table, {room_id, user_id})
    :ok
  end

  @doc "Currently-typing (non-expired) user_ids for room_id."
  def typing_user_ids(room_id) do
    now = System.system_time(:millisecond)

    :ets.foldl(
      fn
        {{r, user_id}, expires_at}, acc when r == room_id and expires_at > now -> [user_id | acc]
        _, acc -> acc
      end,
      [],
      @table
    )
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
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, state}
  end
end
