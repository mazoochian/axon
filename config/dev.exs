import Config

config :axon_core, AxonCore.Repo,
  username: "axon",
  password: "axon",
  hostname: "localhost",
  database: "axon_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :logger, level: :debug
