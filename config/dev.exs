import Config

config :axon_core, AxonCore.Repo,
  username: "axon",
  password: "axon",
  hostname: "localhost",
  database: "axon_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :axon_web, AxonWeb.Endpoint,
  server: true,
  http: [ip: {0, 0, 0, 0}, port: 8008],
  check_origin: false,
  code_reloader: false,
  debug_errors: false,
  secret_key_base: "dev_secret_key_base_000000000000000000000000000000000000000000000000"

config :axon_web, AxonWeb.FederationEndpoint,
  server: true,
  http: [ip: {0, 0, 0, 0}, port: 8448],
  check_origin: false,
  code_reloader: false,
  debug_errors: false,
  secret_key_base: "dev_secret_key_base_000000000000000000000000000000000000000000000000"

config :libcluster, topologies: []

config :logger, level: :debug

# Delegated OAuth2/OIDC auth (MSC3861) — only turns on if OIDC_ISSUER is set
# in the environment, so plain `mix phx.server` still uses password login.
if System.get_env("OIDC_ISSUER") do
  config :axon_web, :oidc,
    enabled: true,
    issuer: System.get_env("OIDC_ISSUER"),
    client_id: System.get_env("OIDC_CLIENT_ID"),
    client_secret: System.get_env("OIDC_CLIENT_SECRET"),
    client_auth_method: System.get_env("OIDC_CLIENT_AUTH_METHOD", "client_secret_basic"),
    account_management_url: System.get_env("OIDC_ACCOUNT_MANAGEMENT_URL")
end
