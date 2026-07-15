import Config

config :axon_core, AxonCore.Repo,
  username: System.get_env("DB_USER", "axon"),
  password: System.get_env("DB_PASS", "axon"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "axon_prod"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "20"))

config :axon_web, AxonWeb.Endpoint,
  server: true,
  secret_key_base: System.get_env("SECRET_KEY_BASE") || String.duplicate("a", 64)

config :axon_web,
  server_name: System.get_env("AXON_SERVER_NAME", System.get_env("SERVER_NAME", "localhost"))

config :axon_federation,
  server_name: System.get_env("AXON_SERVER_NAME", System.get_env("SERVER_NAME", "localhost"))

config :logger, level: :info
