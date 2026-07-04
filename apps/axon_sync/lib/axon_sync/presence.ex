defmodule AxonSync.Presence do
  @moduledoc """
  Presence tracking. Deliberately in-memory (ETS), not persisted: presence
  is ephemeral by spec, and a restart legitimately resetting everyone to
  "unknown until they're next active" is acceptable (and matches how most
  clients already treat a homeserver restart).

  State: a `:set` table of `user_id => {presence, status_msg, last_active_ts,
  version}`, plus an `:ordered_set` change log of `version => user_id` so
  `/sync` can ask "what changed since version V" the same way
  `device_list_updates` does for device keys — just kept in ETS instead of
  Postgres, and trimmed, since old presence history has no lasting value.
  """

  use GenServer

  @table :axon_presence
  @log_table :axon_presence_log
  @tick_interval :timer.seconds(30)
  @idle_after :timer.minutes(5)
  @offline_after :timer.minutes(30)
  @currently_active_window :timer.seconds(30)
  @log_max_size 20_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Explicitly sets a user's presence (from PUT /presence/:userId/status)."
  def set_presence(user_id, presence, status_msg \\ nil)
      when presence in ["online", "unavailable", "offline"] do
    GenServer.call(__MODULE__, {:set_presence, user_id, presence, status_msg})
  end

  @doc """
  Records activity for a user (called on every authenticated request). If
  the user has no presence row yet, or was offline, this brings them online
  — using the API at all implies presence, same as most homeservers.
  """
  def bump_activity(user_id) do
    GenServer.cast(__MODULE__, {:bump_activity, user_id})
  end

  @doc "Returns the current presence map for a user, or the spec default if never seen."
  def get(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, presence, status_msg, last_active_ts, _version}] ->
        to_map(presence, status_msg, last_active_ts)

      [] ->
        to_map("offline", nil, nil)
    end
  end

  @doc "The current global version counter, to stamp into sync tokens."
  def current_version, do: :ets.lookup_element(@table, :__version__, 2)

  @doc """
  Presence maps for `user_ids` that changed after `since_version`, deduped
  to each user's latest state. Pass `since_version: 0` for "all of them".
  """
  def changes_since(user_ids, since_version) do
    wanted = MapSet.new(user_ids)

    :ets.foldl(
      fn
        {version, user_id}, acc when version > since_version ->
          if MapSet.member?(wanted, user_id), do: Map.put(acc, user_id, get(user_id)), else: acc

        _, acc ->
          acc
      end,
      %{},
      @log_table
    )
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init([]) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    :ets.new(@log_table, [:ordered_set, :named_table, :public])
    :ets.insert(@table, {:__version__, 0})
    Process.send_after(self(), :tick, @tick_interval)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:set_presence, user_id, presence, status_msg}, _from, state) do
    now = System.system_time(:millisecond)
    record(user_id, presence, status_msg, now)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:bump_activity, user_id}, state) do
    now = System.system_time(:millisecond)

    {presence, status_msg} =
      case :ets.lookup(@table, user_id) do
        [{^user_id, "offline", msg, _ts, _v}] -> {"online", msg}
        [{^user_id, current, msg, _ts, _v}] -> {current, msg}
        [] -> {"online", nil}
      end

    record(user_id, presence, status_msg, now)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.system_time(:millisecond)

    :ets.foldl(
      fn
        {user_id, presence, status_msg, last_active_ts, _version}, _acc
        when is_binary(user_id) and is_integer(last_active_ts) ->
          idle_for = now - last_active_ts

          cond do
            presence != "offline" and idle_for >= @offline_after ->
              record(user_id, "offline", status_msg, last_active_ts)

            presence == "online" and idle_for >= @idle_after ->
              record(user_id, "unavailable", status_msg, last_active_ts)

            true ->
              :ok
          end

          nil

        _, _acc ->
          nil
      end,
      nil,
      @table
    )

    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp record(user_id, presence, status_msg, last_active_ts) do
    version = :ets.update_counter(@table, :__version__, 1)
    :ets.insert(@table, {user_id, presence, status_msg, last_active_ts, version})
    :ets.insert(@log_table, {version, user_id})
    trim_log()
  end

  defp trim_log do
    case :ets.info(@log_table, :size) do
      size when size > @log_max_size ->
        oldest = :ets.first(@log_table)
        if oldest != :"$end_of_table", do: :ets.delete(@log_table, oldest)

      _ ->
        :ok
    end
  end

  defp to_map(presence, status_msg, last_active_ts) do
    now = System.system_time(:millisecond)

    base = %{
      "presence" => presence,
      "currently_active" =>
        presence == "online" and is_integer(last_active_ts) and
          now - last_active_ts < @currently_active_window
    }

    base =
      if last_active_ts, do: Map.put(base, "last_active_ago", now - last_active_ts), else: base

    if status_msg, do: Map.put(base, "status_msg", status_msg), else: base
  end
end
