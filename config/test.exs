import Config

config :axon_core, AxonCore.Repo,
  username: "axon",
  password: "axon",
  hostname: "localhost",
  database: "axon_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning
