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

# High enough that the test suite's normal traffic (many
# registrations/logins/sends from the same loopback IP across many test
# files) never trips these — the limiter's own behavior is covered by
# dedicated rate_limiter_test.exs / rate_limit_test.exs tests that call it
# directly with small, explicit limits instead of relying on these.
config :axon_web, :rate_limits,
  login: [max: 1_000_000, window_ms: 60_000],
  register: [max: 1_000_000, window_ms: 60_000],
  send_event: [max: 1_000_000, window_ms: 10_000],
  media_upload: [max: 1_000_000, window_ms: 60_000],
  url_preview: [max: 1_000_000, window_ms: 60_000],
  search: [max: 1_000_000, window_ms: 60_000],
  sync: [max: 1_000_000, window_ms: 60_000]

config :logger, level: :warning
