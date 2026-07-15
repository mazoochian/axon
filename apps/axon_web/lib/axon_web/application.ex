defmodule AxonWeb.Application do
  use Application

  @impl true
  def start(_type, _args) do
    attach_sentry_logger_handler()

    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      # Server signing key — must start before the endpoint
      {AxonCrypto.KeyServer, server_name: Application.fetch_env!(:axon_web, :server_name)},
      # Telemetry poller + metrics (Phoenix/Ecto/VM/mailbox-depth), feeds LiveDashboard
      AxonWeb.Telemetry,
      # HTTP client for outbound federation requests
      {Finch, name: Axon.Finch},
      # Caches the delegated OIDC Authorization Server's discovery document
      AxonWeb.Oidc.Discovery,
      # Task supervisor for async federation work
      {Task.Supervisor, name: Axon.TaskSupervisor},
      # Federation outbound fan-out (subscribes to PubSub, sends PDUs to remote servers)
      AxonWeb.FederationFanout,
      # Application service manager (loads AS registrations, dispatches events)
      AxonWeb.AppService.Manager,
      # In-memory rate limiter (login/register/message-send)
      AxonWeb.RateLimiter,
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

  # Only attaches when SENTRY_DSN is actually set (config/runtime.exs, prod
  # only) — a no-op in dev/test, so this can't add per-log-call overhead or
  # behavior change to the test suite.
  defp attach_sentry_logger_handler do
    if Application.get_env(:sentry, :dsn) do
      :logger.add_handler(:axon_sentry_handler, Sentry.LoggerHandler, %{
        config: %{metadata: [:user_id, :room_id, :request_id], capture_log_messages: true}
      })
    end
  end
end
