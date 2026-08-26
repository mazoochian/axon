import Config

# Compile-time prod config. Everything secret is set in config/runtime.exs
# instead, which reads the environment on boot and *raises* when a required
# value is missing (SECRET_KEY_BASE, DB_PASS) — deliberately no defaults
# here, because a compile-time default silently wins whenever runtime.exs
# hasn't overridden it yet, and a guessable one is worse than a crash.
#
# `secret_key_base` in particular used to default to `String.duplicate("a", 64)`,
# which keys every Plug.Crypto-signed cookie, CSRF token and Phoenix.Token
# the server issues; a known value there is forgeable by anyone who has read
# this repo. `password` defaulted to "axon" for the same class of reason.
config :axon_core, AxonCore.Repo,
  username: System.get_env("DB_USER", "axon"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "axon_prod"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "20"))

config :axon_web, AxonWeb.Endpoint, server: true

config :axon_web,
  server_name: System.get_env("AXON_SERVER_NAME", System.get_env("SERVER_NAME", "localhost"))

config :axon_federation,
  server_name: System.get_env("AXON_SERVER_NAME", System.get_env("SERVER_NAME", "localhost"))

config :logger, level: :info
