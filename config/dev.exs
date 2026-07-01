import Config

config :axon_core, AxonCore.Repo,
  username: "axon",
  password: "axon",
  hostname: "localhost",
  database: "axon_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :axon_web, AxonWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 8008],
  check_origin: false,
  code_reloader: false,
  debug_errors: false,
  secret_key_base: "dev_secret_key_base_000000000000000000000000000000000000000000000000"

config :axon_web, AxonWeb.FederationEndpoint,
  http: [ip: {127, 0, 0, 1}, port: 8448],
  check_origin: false,
  code_reloader: false,
  debug_errors: false,
  secret_key_base: "dev_secret_key_base_000000000000000000000000000000000000000000000000"

config :libcluster, topologies: []

config :logger, level: :debug
