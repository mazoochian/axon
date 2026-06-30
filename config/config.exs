import Config

# Server identity
config :axon_web,
  server_name: System.get_env("AXON_SERVER_NAME", "localhost")

# Ecto repo
config :axon_core, AxonCore.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: System.get_env("DB_USER", "axon"),
  password: System.get_env("DB_PASS", "axon"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "axon_dev"),
  pool_size: 20

config :axon_core, ecto_repos: [AxonCore.Repo]

# Phoenix endpoint
config :axon_web, AxonWeb.Endpoint,
  http: [port: 8008],
  secret_key_base: System.get_env("SECRET_KEY_BASE", String.duplicate("a", 64))

# Federation HTTP listener (separate port)
config :axon_federation,
  http_port: 8448,
  server_name: System.get_env("AXON_SERVER_NAME", "localhost")

# Media storage backend: :local or :s3
config :axon_media,
  backend: :local,
  local_path: "priv/media"

# Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :room_id, :user_id]

# Phoenix PubSub
config :axon_sync,
  pubsub: [name: Axon.PubSub, adapter: Phoenix.PubSub.PG2]

import_config "#{config_env()}.exs"
