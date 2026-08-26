import Config

# Last-resort `secret_key_base` for the two endpoints below, used only when
# nothing else supplies one — dev/test set their own literal, and prod takes
# it from SECRET_KEY_BASE in config/runtime.exs, which *raises* rather than
# defaulting. This used to be `String.duplicate("a", 64)`: a fixed, published
# value keying every signed/encrypted cookie, CSRF token and Phoenix.Token
# the server issues, and therefore forgeable by anyone who has read this
# repo. Random per build instead, so an unconfigured endpoint is at worst
# useless across restarts rather than trivially forgeable.
random_secret_key_base = fn -> 48 |> :crypto.strong_rand_bytes() |> Base.encode64() end

# Server identity
config :axon_web,
  server_name: System.get_env("AXON_SERVER_NAME", "localhost")

# The build's Mix environment, recorded so runtime code can ask. `Mix.env/0`
# itself does not exist in a release — Mix isn't in the runtime dependency
# tree — so anything that needs to behave differently in a real deployment
# than in dev/test (see AxonWeb.StartupChecks, which only warns about
# risky-but-legal configuration when this says :prod) has to be told at
# build time rather than inferring it.
config :axon_web, :env, config_env()

# Identity server for 3pid invites (see AxonWeb.IdentityServer,
# AxonWeb.RoomController.invite_3pid/4, and README.md's "Identity server
# (3pid invites)"). A plain base URL, e.g. "https://vector.im" or a local
# dev Sydent at "http://localhost:8090" — unset means no identity-server
# integration beyond what the inviting client supplies itself via
# id_server/id_access_token.
config :axon_web, :default_identity_server, System.get_env("DEFAULT_IDENTITY_SERVER")

# Delegated OAuth 2.0 / OIDC auth (MSC3861 / MSC2965) — off by default.
# When enabled, this homeserver acts purely as an OAuth2 resource server:
# it does not mint its own access tokens or accept m.login.password/register;
# clients discover the external Authorization Server via auth_metadata and
# talk to it directly, and Axon validates their tokens via introspection.
config :axon_web, :oidc,
  enabled: false,
  issuer: nil,
  client_id: nil,
  client_secret: nil,
  client_auth_method: "client_secret_basic",
  account_management_url: nil

# Open self-registration (`POST /register` with no auth) — off by default,
# matching Synapse's own `enable_registration: false` safe default. When
# disabled (and OIDC isn't handling registration instead), AuthController
# rejects with the same 403 M_FORBIDDEN "Registration has been disabled"
# Synapse returns. See config/runtime.exs for how a real deployment turns
# this on via REGISTRATION_ENABLED, and config/dev.exs / config/test.exs
# for why it's kept on there.
config :axon_web, :registration, enabled: false

# Refresh tokens (stable Matrix spec, formerly MSC2918). Defaults mirror
# Synapse's own (synapse/config/registration.py):
#   - `access_token_lifetime_ms` is the lifetime given to an access token
#     minted *because* `refresh_token: true` was requested at
#     login/register, or by /refresh — Synapse's
#     `refreshable_access_token_lifetime` default is "5m".
#   - `refresh_token_lifetime_ms` is nil (never expires) by default,
#     matching Synapse's `refresh_token_lifetime: None` default — a
#     refresh token still stops working the moment it's used once
#     (single-use rotation), it just doesn't also carry a clock.
# An access token minted *without* requesting a refresh token is
# unaffected by either setting: it keeps Axon's pre-existing behavior of
# never expiring, matching Synapse's `nonrefreshable_access_token_lifetime:
# None` default.
config :axon_web, :refresh_tokens,
  access_token_lifetime_ms: 300_000,
  refresh_token_lifetime_ms: nil

# Ecto repo
config :axon_core, AxonCore.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: System.get_env("DB_USER", "axon"),
  password: System.get_env("DB_PASS", "axon"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "axon_dev"),
  pool_size: 20

config :axon_core, AxonCore.AdvisoryLockRepo,
  adapter: Ecto.Adapters.Postgres,
  username: System.get_env("DB_USER", "axon"),
  password: System.get_env("DB_PASS", "axon"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "axon_dev"),
  pool_size: 2

config :axon_core, ecto_repos: [AxonCore.Repo]

# Phoenix endpoint
config :axon_web, AxonWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 8008],
  url: [host: "localhost"],
  secret_key_base: System.get_env("SECRET_KEY_BASE") || random_secret_key_base.(),
  render_errors: [
    formats: [json: AxonWeb.FallbackController],
    layout: false
  ],
  pubsub_server: Axon.PubSub,
  live_view: [signing_salt: "axon_lv"]

# Federation HTTP listener (separate port)
config :axon_federation,
  http_port: 8448,
  server_name: System.get_env("AXON_SERVER_NAME", "localhost"),
  # Max concurrent in-flight delivery attempts per remote destination —
  # see AxonFederation.OutboundQueue's moduledoc (Phase 15.4).
  outbound_concurrency_per_destination: 5

config :axon_web, AxonWeb.FederationEndpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 8448],
  url: [host: "localhost"],
  secret_key_base: System.get_env("SECRET_KEY_BASE") || random_secret_key_base.(),
  render_errors: [formats: [json: AxonWeb.FallbackController], layout: false],
  pubsub_server: Axon.PubSub

# Rate limits (Phase 13, extended Phase 15.4). Each bucket is [max: N,
# window_ms: M] — N requests per M milliseconds, keyed per-IP
# (login/register) or per-user (everything else). See AxonWeb.Plug.RateLimit.
#
# `sync` is intentionally far more generous than the others: legitimate
# clients long-poll it continuously (and re-call immediately whenever the
# poll returns), so a naive per-request-count limit sized like login/search
# would false-positive on normal usage rather than actually catching abuse.
# `login` is limited on two independent dimensions: `login` per source IP
# (how fast one host can guess), and `login_account` per targeted localpart
# (how fast one *account* can be guessed at, from however many hosts).
# Per-IP alone is not a per-account lockout — a thousand IPs doing ten
# attempts each never trip it while putting ten thousand guesses on one
# password — so credential stuffing against a single account was, in
# effect, unthrottled. The per-account window is deliberately wider and
# more generous than the per-IP one: it is shared by everyone legitimately
# signing in to that account (several devices, an app retrying), and a
# limit tight enough to be a lockout is a limit an attacker can use *as*
# a lockout.
#
# `ui_auth` covers the password-verifying User-Interactive Auth stages
# (`/account/password`, `/account/deactivate`), keyed per user. Those run
# `Argon2.verify_pass` — deliberately expensive — with nothing between
# them and an authenticated caller, so they were both an online
# password-guessing oracle against the caller's own account and a cheap
# way to make this server burn CPU. `refresh` is keyed per IP, since it
# carries no access token: the refresh token in the body *is* the
# credential being presented, and an unthrottled endpoint that validates a
# secret is an endpoint that can be guessed at.
config :axon_web, :rate_limits,
  login: [max: 10, window_ms: 60_000],
  login_account: [max: 30, window_ms: 300_000],
  register: [max: 5, window_ms: 60_000],
  send_event: [max: 20, window_ms: 10_000],
  media_upload: [max: 20, window_ms: 60_000],
  url_preview: [max: 20, window_ms: 60_000],
  search: [max: 20, window_ms: 60_000],
  sync: [max: 300, window_ms: 60_000],
  admin_register: [max: 5, window_ms: 60_000],
  ui_auth: [max: 10, window_ms: 60_000],
  refresh: [max: 30, window_ms: 60_000]

# Phoenix logs request parameters at :info for every controller action, and
# `password`/`access_token`/`mac` are all ordinary body params on this API
# — an unfiltered log is a plaintext credential store with a retention
# policy nobody wrote down. There was no `filter_parameters` set at all,
# which means Phoenix's own default (`["password"]`) applied and everything
# else went to the log verbatim.
#
# Matching is by substring on the parameter *name*, so each entry covers a
# family: `token` catches `access_token`, `refresh_token` and
# `id_access_token`; `password` catches `new_password`; `secret` catches
# `client_secret`; `mac` is the shared-secret admin bootstrap's HMAC.
# Deliberately *not* here: `key` and `signature`. Device keys, cross-signing
# keys and event signatures are public by design, and a substring match on
# `key` would swallow `state_key`, `room_key`s and `key_name` too — cost to
# debuggability with nothing bought.
#
# This also covers the audit's L2: access tokens are accepted in the
# `?access_token=` query string (spec-permitted legacy behavior real
# clients still rely on, so it stays), and query params reach the log
# through the same mechanism and are filtered by the same list. The
# request *line* Phoenix logs is `conn.request_path`, which carries no
# query string, so nothing else needs redacting there.
config :phoenix, :filter_parameters, ["password", "token", "mac", "secret"]

# Shared secret for the Synapse-compatible `/_synapse/admin/v1/register`
# bootstrap endpoint. No default on purpose: nil means the endpoint (and its
# nonce companion) answer 404 M_UNRECOGNIZED instead of accepting a MAC
# computed with a value an attacker could read out of this repo. prod sources
# it from REGISTRATION_SHARED_SECRET (config/runtime.exs); dev/test set a
# fixed convenience value. See AxonWeb.AuthController.
config :axon_web, :registration_shared_secret, nil

# Media storage backend: :local or :s3
config :axon_media,
  backend: :local,
  local_path: "priv/media"

# Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :room_id, :user_id]

# Sentry (Phase 15.3) — dsn is nil here and stays nil in dev/test, in which
# case the SDK no-ops on every capture call rather than failing. Only
# config/runtime.exs (prod, from SENTRY_DSN) turns it on for real; the
# logger handler in AxonWeb.Application is only attached when a dsn is set.
config :sentry,
  environment_name: to_string(config_env()),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()]

# Phoenix PubSub
config :axon_sync,
  pubsub: [name: Axon.PubSub, adapter: Phoenix.PubSub.PG2]

import_config "#{config_env()}.exs"
