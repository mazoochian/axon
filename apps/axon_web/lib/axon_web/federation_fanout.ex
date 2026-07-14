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
    origin = KeyServer.server_name()

    Enum.each(remote_servers, fn server ->
      OutboundQueue.enqueue(server, %{
        "origin" => origin,
        "origin_server_ts" => System.os_time(:millisecond),
        "pdus" => [event_map]
      })
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:federate_edu, edu, destination_server}, state) do
    origin = KeyServer.server_name()

    OutboundQueue.enqueue(destination_server, %{
      "origin" => origin,
      "origin_server_ts" => System.os_time(:millisecond),
      "pdus" => [],
      "edus" => [edu]
    })

    {:noreply, state}
  end

  @impl true
  def handle_info({:presence_changed, user_id, presence_map}, state) do
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

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
