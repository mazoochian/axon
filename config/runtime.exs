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

  config :axon_web, AxonWeb.Endpoint,
    server: true,
    secret_key_base: secret_key_base

  config :axon_web, server_name: server_name
  config :axon_federation, server_name: server_name

  config :axon_web, AxonWeb.FederationEndpoint,
    server: true,
    secret_key_base: secret_key_base

  if System.get_env("OIDC_ISSUER") do
    config :axon_web, :oidc,
      enabled: true,
      issuer: System.get_env("OIDC_ISSUER"),
      client_id: System.get_env("OIDC_CLIENT_ID"),
      client_secret: System.get_env("OIDC_CLIENT_SECRET"),
      client_auth_method: System.get_env("OIDC_CLIENT_AUTH_METHOD", "client_secret_basic"),
      account_management_url: System.get_env("OIDC_ACCOUNT_MANAGEMENT_URL")
  end

  # Optional — leave SENTRY_DSN unset to run without error tracking.
  config :sentry, dsn: System.get_env("SENTRY_DSN")

  # Complement's compliance harness legitimately registers/sends far more
  # rapidly than the production anti-abuse limits in config.exs allow per
  # IP/user (e.g. several users joined across homeservers within seconds) —
  # set by complement/start.sh, not intended for a real deployment. Mirrors
  # config/test.exs's approach: the limiter's own behavior is covered by
  # rate_limit_test.exs regardless of these being relaxed here.
  if System.get_env("RELAXED_RATE_LIMITS") == "true" do
    config :axon_web, :rate_limits,
      login: [max: 1_000_000, window_ms: 60_000],
      register: [max: 1_000_000, window_ms: 60_000],
      send_event: [max: 1_000_000, window_ms: 10_000],
      media_upload: [max: 1_000_000, window_ms: 60_000],
      url_preview: [max: 1_000_000, window_ms: 60_000],
      search: [max: 1_000_000, window_ms: 60_000],
      sync: [max: 1_000_000, window_ms: 60_000]
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
