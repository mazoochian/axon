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
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 8008],
  url: [host: "localhost"],
  secret_key_base: System.get_env("SECRET_KEY_BASE", String.duplicate("a", 64)),
  render_errors: [
    formats: [json: AxonWeb.FallbackController],
    layout: false
  ],
  pubsub_server: Axon.PubSub,
  live_view: [signing_salt: "axon_lv"]

# Federation HTTP listener (separate port)
config :axon_federation,
  http_port: 8448,
  server_name: System.get_env("AXON_SERVER_NAME", "localhost")

config :axon_web, AxonWeb.FederationEndpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 8448],
  url: [host: "localhost"],
  secret_key_base: System.get_env("SECRET_KEY_BASE", String.duplicate("a", 64)),
  render_errors: [formats: [json: AxonWeb.FallbackController], layout: false],
  pubsub_server: Axon.PubSub

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
