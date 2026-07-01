defmodule AxonSync.Manager do
  @moduledoc """
  Manages long-polling /sync connections.

  Each connected sync client is tracked as a waiter. When new events arrive
  (via Phoenix.PubSub broadcast from RoomProcess), all waiters for affected
  users are notified.

  Design: sync controllers register themselves with a `{user_id, from_ordering}`
  tuple, then block in a receive. This module notifies them via `send/2` when
  relevant events arrive.
  """

  use GenServer

  alias AxonCore.EventStore

  @pubsub Axon.PubSub

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Waits for events for user_id with stream_ordering > since_ordering.

  Blocks for up to `timeout` ms (default 30_000). Returns `{:ok, events_by_room}`.
  If no events arrive, returns `{:ok, %{}}`.
  """
  def wait_for_events(user_id, since_ordering, timeout \\ 30_000) do
    # Subscribe to rooms this user is in
    joined_rooms = EventStore.get_joined_rooms(user_id)
    Enum.each(joined_rooms, fn room_id ->
      Phoenix.PubSub.subscribe(@pubsub, "room:#{room_id}")
    end)

    # Also subscribe to user-specific channel (to-device, account data)
    Phoenix.PubSub.subscribe(@pubsub, "user:#{user_id}")

    # Check if events already exist (race-free: subscribe first, then check)
    events = EventStore.get_user_events_since(user_id, since_ordering)

    if events != %{} do
      unsubscribe_all(joined_rooms, user_id)
      {:ok, events}
    else
      result = wait_loop(user_id, since_ordering, timeout)
      unsubscribe_all(joined_rooms, user_id)
      result
    end
  end

  # ---------------------------------------------------------------------------
  # Server callbacks (minimal — actual work happens in caller process)
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{}}

  # ---------------------------------------------------------------------------
  # Private: per-process wait loop
  # ---------------------------------------------------------------------------

  defp wait_loop(user_id, since_ordering, timeout) do
    receive do
      {:new_event, _room_id, _event_map} ->
        # An event arrived in one of our subscribed rooms.
        # Re-query to get all new events atomically.
        events = EventStore.get_user_events_since(user_id, since_ordering)
        if events != %{}, do: {:ok, events}, else: wait_loop(user_id, since_ordering, timeout)

      {:to_device, _messages} ->
        # To-device messages arrived; return immediately.
        events = EventStore.get_user_events_since(user_id, since_ordering)
        {:ok, events}

      :sync_timeout ->
        {:ok, %{}}
    after
      timeout -> {:ok, %{}}
    end
  end

  defp unsubscribe_all(rooms, user_id) do
    Enum.each(rooms, fn room_id ->
      Phoenix.PubSub.unsubscribe(@pubsub, "room:#{room_id}")
    end)
    Phoenix.PubSub.unsubscribe(@pubsub, "user:#{user_id}")
  end
end
