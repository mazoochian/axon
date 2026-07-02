defmodule AxonWeb.FederationFanout do
  @moduledoc """
  Subscribes to PubSub federation:fanout events and sends PDUs to remote servers.
  """

  use GenServer
  require Logger

  alias AxonFederation.HttpClient
  alias AxonCrypto.KeyServer

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
    txn_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

    Task.Supervisor.start_child(Axon.TaskSupervisor, fn ->
      Enum.each(remote_servers, fn server ->
        case HttpClient.put(
               server,
               "/_matrix/federation/v1/send/#{txn_id}",
               %{
                 "origin" => origin,
                 "origin_server_ts" => System.os_time(:millisecond),
                 "pdus" => [event_map]
               }
             ) do
          {:ok, _} -> :ok
          {:error, reason} ->
            Logger.warning("Fan-out to #{server} failed: #{inspect(reason)}")
        end
      end)
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
