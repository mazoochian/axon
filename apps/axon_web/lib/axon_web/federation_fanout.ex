defmodule AxonWeb.FederationFanout do
  @moduledoc """
  Subscribes to PubSub federation:fanout events and hands PDUs/EDUs off to
  AxonFederation.OutboundQueue for durable delivery (persisted, retried with
  backoff on failure).

  This module exists only to bridge PubSub messages from axon_room (PDUs)
  and axon_web controllers (EDUs) into that queue — it avoids a cross-app
  dependency from axon_room to axon_federation, since they sit at the same
  supervision level in the umbrella.
  """

  use GenServer

  alias AxonCore.EventStore
  alias AxonCrypto.KeyServer
  alias AxonFederation.OutboundQueue

  @pubsub Axon.PubSub

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub, "federation:fanout")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:federate_event, event_map, remote_servers}, state) do
    guarded(fn ->
      origin = KeyServer.server_name()

      Enum.each(remote_servers, fn server ->
        OutboundQueue.enqueue(server, %{
          "origin" => origin,
          "origin_server_ts" => System.os_time(:millisecond),
          "pdus" => [event_map]
        })
      end)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:federate_edu, edu, destination_server}, state) do
    guarded(fn ->
      origin = KeyServer.server_name()

      OutboundQueue.enqueue(destination_server, %{
        "origin" => origin,
        "origin_server_ts" => System.os_time(:millisecond),
        "pdus" => [],
        "edus" => [edu]
      })
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:presence_changed, user_id, presence_map}, state) do
    guarded(fn ->
      origin = KeyServer.server_name()

      case EventStore.remote_servers_for_user(user_id) do
        [] ->
          :ok

        remote_servers ->
          edu = %{
            "edu_type" => "m.presence",
            "content" => %{"push" => [Map.put(presence_map, "user_id", user_id)]}
          }

          Enum.each(remote_servers, fn server ->
            OutboundQueue.enqueue(server, %{
              "origin" => origin,
              "origin_server_ts" => System.os_time(:millisecond),
              "pdus" => [],
              "edus" => [edu]
            })
          end)
      end
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # This GenServer subscribes to PubSub topics that other long-lived,
  # timer-driven processes (AxonSync.Presence, AxonRoom.RoomProcess) publish
  # to independently of any test's lifecycle. Under the Ecto sandbox, a
  # message that happens to arrive in the gap between two tests (nothing
  # currently owns/allows a sandboxed connection) raises
  # DBConnection.OwnershipError from the Repo calls above — uncaught, that
  # crashes this GenServer, and since nothing else in the umbrella retries
  # a dropped PubSub message, repeated crashes exhaust the supervisor's
  # restart intensity and take down the whole axon_web application with
  # it (every subsequent test then fails with an unrelated-looking "ETS
  # table does not exist" from Endpoint.config/2). Dropping one fanout
  # message here is harmless in that scenario — same tradeoff, same
  # pattern, as AxonFederation.OutboundQueue's and DeviceListFanout's
  # own sweep guards.
  defp guarded(fun) do
    try do
      fun.()
    rescue
      _ in [DBConnection.OwnershipError, DBConnection.ConnectionError] -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
