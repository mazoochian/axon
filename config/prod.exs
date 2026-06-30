import Config

config :axon_core, AxonCore.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "20")),
  ssl: true

config :axon_web, AxonWeb.Endpoint,
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE")

config :axon_web,
  server_name: System.fetch_env!("AXON_SERVER_NAME")

config :axon_federation,
  server_name: System.fetch_env!("AXON_SERVER_NAME")

config :logger, level: :info
