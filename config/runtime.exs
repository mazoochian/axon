import Config

if config_env() == :prod do
  server_name = System.get_env("SERVER_NAME") || System.get_env("AXON_SERVER_NAME") || "localhost"

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  db_pass =
    System.get_env("DB_PASS") ||
      raise "environment variable DB_PASS is missing"

  config :axon_core, AxonCore.Repo,
    username: System.get_env("DB_USER", "axon"),
    password: db_pass,
    hostname: System.get_env("DB_HOST", "localhost"),
    database: System.get_env("DB_NAME", "axon_prod"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "20"))

  config :axon_core, AxonCore.AdvisoryLockRepo,
    username: System.get_env("DB_USER", "axon"),
    password: db_pass,
    hostname: System.get_env("DB_HOST", "localhost"),
    database: System.get_env("DB_NAME", "axon_prod"),
    pool_size: 2

  config :axon_web, AxonWeb.Endpoint,
    server: true,
    secret_key_base: secret_key_base

  config :axon_web, server_name: server_name
  config :axon_federation, server_name: server_name

  config :axon_web, AxonWeb.FederationEndpoint,
    server: true,
    secret_key_base: secret_key_base

  # Optional — leave unset and the server's Ed25519 signing identity is
  # regenerated fresh (in memory only) on every restart, which is fine for
  # a one-off/throwaway deployment but invalidates every cached
  # `/_matrix/key/v2/server` response and every signature another server
  # already verified against the old key on a real, long-lived one. Point
  # this at a path on a persistent volume to keep the same identity across
  # restarts (generated and written there on first boot if it doesn't
  # exist yet). See AxonCrypto.KeyServer.
  config :axon_crypto, signing_key_path: System.get_env("SIGNING_KEY_PATH")

  if System.get_env("OIDC_ISSUER") do
    config :axon_web, :oidc,
      enabled: true,
      issuer: System.get_env("OIDC_ISSUER"),
      client_id: System.get_env("OIDC_CLIENT_ID"),
      client_secret: System.get_env("OIDC_CLIENT_SECRET"),
      client_auth_method: System.get_env("OIDC_CLIENT_AUTH_METHOD", "client_secret_basic"),
      account_management_url: System.get_env("OIDC_ACCOUNT_MANAGEMENT_URL")
  end

  # Open self-registration (`POST /register` with no auth) — off unless
  # explicitly turned on, matching Synapse's own `enable_registration: false`
  # safe default (any public non-OIDC deployment left registration wide open,
  # rate-limited only, otherwise). Set REGISTRATION_ENABLED=true to allow
  # public self-registration; leave unset/false and AuthController rejects
  # with 403 M_FORBIDDEN, same as when OIDC (config above) handles
  # registration instead. The _synapse/admin/v1/register shared-secret
  # endpoint is unaffected either way.
  config :axon_web, :registration,
    enabled: System.get_env("REGISTRATION_ENABLED", "false") == "true"

  # Shared secret for the Synapse-compatible `/_synapse/admin/v1/register`
  # bootstrap (and its nonce endpoint). Deliberately *not* defaulted: leave
  # REGISTRATION_SHARED_SECRET unset and both endpoints answer 404
  # M_UNRECOGNIZED, which is the right posture for a deployment that already
  # has its admins. This replaces a compiled-in literal ("complement") that
  # shipped identically in every build — i.e. a publicly-known key to a
  # full-admin account on any Axon server. Generate with `openssl rand -hex 32`
  # if you need the bootstrap; complement/start.sh sets it to "complement",
  # the value Complement's own harness expects. See AxonWeb.AuthController.
  config :axon_web, :registration_shared_secret, System.get_env("REGISTRATION_SHARED_SECRET")

  # Off unless explicitly turned on — a real deployment must keep blocking
  # SSRF-risky private/loopback/link-local targets. complement/start.sh sets
  # URL_PREVIEW_ALLOW_PRIVATE_ADDRESSES=true because Complement's own
  # `TestUrlPreview` webserver is only reachable via the Docker host gateway
  # address, which is itself private — see AxonMedia.UrlPreview.
  config :axon_media,
    url_preview_allow_private_addresses:
      System.get_env("URL_PREVIEW_ALLOW_PRIVATE_ADDRESSES", "false") == "true"

  # Same shape, same reasoning, for remote *media* fetches: the
  # download/thumbnail endpoints take the origin server name straight out of
  # the request URL, so without this guard an unauthenticated client can aim
  # the homeserver's outbound connection at any internal address it likes.
  # Off unless explicitly turned on. complement/start.sh sets
  # FEDERATION_ALLOW_PRIVATE_ADDRESSES=true because every Complement
  # homeserver lives on a private Docker network address — see
  # AxonFederation.AddressGuard.
  config :axon_federation,
    allow_private_addresses:
      System.get_env("FEDERATION_ALLOW_PRIVATE_ADDRESSES", "false") == "true"

  # Optional — leave AXON_APPSERVICE_DIR unset outside Complement.
  # complement/start.sh sets this to /complement/appservice, the fixed
  # path Complement copies one Synapse-style registration YAML into per
  # configured application service — see AxonWeb.AppService.Manager and
  # AxonWeb.AppService.RegistrationYaml.
  config :axon_web, :appservice_dir, System.get_env("AXON_APPSERVICE_DIR")

  # Optional — leave SMTP_HOST unset and 3pid (email) invites stay
  # out-of-band only, same as before AxonWeb.Mailer existed. SMTP_FROM
  # defaults to a generic no-reply at this server's own name; SMTP_TLS
  # defaults to "if_available" (upgrade via STARTTLS when the relay
  # offers it, don't hard-require it) rather than "always", since not
  # every relay an operator points this at will support it.
  if System.get_env("SMTP_HOST") do
    config :axon_web, :smtp,
      relay: System.get_env("SMTP_HOST"),
      port: String.to_integer(System.get_env("SMTP_PORT", "587")),
      username: System.get_env("SMTP_USERNAME"),
      password: System.get_env("SMTP_PASSWORD"),
      tls: String.to_atom(System.get_env("SMTP_TLS", "if_available")),
      from: System.get_env("SMTP_FROM", "no-reply@#{server_name}")
  end

  # Optional — leave SENTRY_DSN unset to run without error tracking.
  config :sentry, dsn: System.get_env("SENTRY_DSN")

  # Complement's compliance harness legitimately registers/sends far more
  # rapidly than the production anti-abuse limits in config.exs allow per
  # IP/user (e.g. several users joined across homeservers within seconds) —
  # set by complement/start.sh, not intended for a real deployment. Mirrors
  # config/test.exs's approach: the limiter's own behavior is covered by
  # rate_limit_test.exs regardless of these being relaxed here.
  #
  # `:relaxed_rate_limits` is set alongside them so the fact is visible to
  # something other than a careful reading of the numbers:
  # `AxonWeb.StartupChecks` logs a loud warning at boot when it's on, which
  # is the difference between "rate limiting is off in this deployment" being
  # discoverable and it being silent. Everything here is prod-only config, so
  # a warning at boot is the only place it can be said.
  if System.get_env("RELAXED_RATE_LIMITS") == "true" do
    config :axon_web, :relaxed_rate_limits, true

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
  end

  # Real Matrix federation is TLS-only. In a typical deployment that
  # termination happens at a reverse proxy in front of this container (hence
  # the endpoint defaulting to plain HTTP), but Complement connects directly
  # to the federation port and expects it to speak TLS itself — it accepts
  # any self-signed cert (InsecureSkipVerify on its client), so no CA
  # chain/hostname matching is required here. Set by complement/start.sh.
  fed_tls_cert = System.get_env("FEDERATION_TLS_CERT_FILE")
  fed_tls_key = System.get_env("FEDERATION_TLS_KEY_FILE")

  if fed_tls_cert && fed_tls_key do
    config :axon_web, AxonWeb.FederationEndpoint,
      http: false,
      https: [
        ip: {0, 0, 0, 0},
        port: 8448,
        cipher_suite: :strong,
        certfile: fed_tls_cert,
        keyfile: fed_tls_key
      ]
  end

  # Extra CA to trust for *outbound* federation requests (Axon.Finch), on
  # top of the normal OTP root store — lets two Complement-spawned
  # homeservers, both signed by Complement's shared CA, validate each
  # other's federation cert normally instead of failing chain validation.
  # See complement/start.sh.
  config :axon_web, :federation_extra_cacertfile, System.get_env("FEDERATION_TLS_CA_FILE")
end
