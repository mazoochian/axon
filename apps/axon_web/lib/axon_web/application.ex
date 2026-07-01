defmodule AxonWeb.Application do
  use Application

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      # Server signing key — must start before the endpoint
      {AxonCrypto.KeyServer,
       server_name: Application.fetch_env!(:axon_web, :server_name)},
      # HTTP client for outbound federation requests
      {Finch, name: Axon.Finch},
      # Cluster auto-discovery
      {Cluster.Supervisor, [topologies, [name: Axon.ClusterSupervisor]]},
      # CS API endpoint (port 8008)
      AxonWeb.Endpoint,
      # Federation endpoint (port 8448) — shares same router
      AxonWeb.FederationEndpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AxonWeb.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AxonWeb.Endpoint.config_change(changed, removed)
    AxonWeb.FederationEndpoint.config_change(changed, removed)
    :ok
  end
end
