import Config

config :axon_core, AxonCore.Repo,
  username: "axon",
  password: "axon",
  hostname: "localhost",
  database: "axon_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :axon_web, AxonWeb.Endpoint,
  server: false,
  secret_key_base: String.duplicate("test", 16)

config :axon_web, AxonWeb.FederationEndpoint,
  server: false,
  secret_key_base: String.duplicate("test", 16)

config :libcluster, topologies: []

config :logger, level: :warning
