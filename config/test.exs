import Config

config :axon_core, AxonCore.Repo,
  username: "axon",
  password: "axon",
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  # Overridable so several concurrent test runs (e.g. one per git worktree)
  # can each own an isolated database instead of trampling the shared
  # sandbox on this box's single local Postgres instance.
  database: System.get_env("AXON_TEST_DB", "axon_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :axon_core, AxonCore.AdvisoryLockRepo,
  username: "axon",
  password: "axon",
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  database: System.get_env("AXON_TEST_DB", "axon_test"),
  pool: DBConnection.ConnectionPool,
  pool_size: 2

# SQL Sandbox owns an outer transaction before test code runs, so PostgreSQL
# cannot accept SET TRANSACTION there. Production keeps the default true; the
# non-sandbox isolation regression uses AdvisoryLockRepo and still executes it.
config :axon_core, :snapshot_set_transaction_isolation, false

config :axon_web, AxonWeb.Endpoint,
  server: false,
  secret_key_base: String.duplicate("test", 16)

config :axon_web, AxonWeb.FederationEndpoint,
  server: false,
  secret_key_base: String.duplicate("test", 16)

config :libcluster, topologies: []

# Open self-registration — the test suite creates users via
# POST /register throughout, so keep it enabled here regardless of prod's
# safe (disabled) default. See config/runtime.exs.
config :axon_web, :registration, enabled: true

# High enough that the test suite's normal traffic (many
# registrations/logins/sends from the same loopback IP across many test
# files) never trips these — the limiter's own behavior is covered by
# dedicated rate_limiter_test.exs / rate_limit_test.exs tests that call it
# directly with small, explicit limits instead of relying on these.
config :axon_web, :rate_limits,
  login: [max: 1_000_000, window_ms: 60_000],
  login_account: [max: 1_000_000, window_ms: 300_000],
  register: [max: 1_000_000, window_ms: 60_000],
  send_event: [max: 1_000_000, window_ms: 10_000],
  media_upload: [max: 1_000_000, window_ms: 60_000],
  url_preview: [max: 1_000_000, window_ms: 60_000],
  search: [max: 1_000_000, window_ms: 60_000],
  sync: [max: 1_000_000, window_ms: 60_000],
  admin_register: [max: 1_000_000, window_ms: 60_000],
  ui_auth: [max: 1_000_000, window_ms: 60_000],
  refresh: [max: 1_000_000, window_ms: 60_000]

# Fixed convenience value for the shared-secret admin bootstrap
# (`/_synapse/admin/v1/register`) — prod requires REGISTRATION_SHARED_SECRET
# from the environment and disables the endpoint outright when it's unset.
# Matches what complement/start.sh exports, since Complement's own harness
# hardcodes "complement" as the registration shared secret.
config :axon_web, :registration_shared_secret, "complement"

# Remote-media/key fetches are SSRF-guarded against private/loopback/
# link-local addresses (AxonFederation.AddressGuard), which every fake
# remote server in this suite is — they're Bandit listeners on 127.0.0.1
# reached via `:server_overrides`. Unlike `:axon_media,
# :url_preview_allow_private_addresses` below (which individual tests flip
# on only where they specifically need to reach a loopback fixture), this
# stays on suite-wide: fake remote servers are pervasive across the
# federation test suite, not a handful of opt-in cases.
config :axon_federation, :allow_private_addresses, true
config :axon_media, :url_preview_allow_private_addresses, false

config :logger, level: :warning
