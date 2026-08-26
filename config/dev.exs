import Config

config :axon_core, AxonCore.Repo,
  username: "axon",
  password: "axon",
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
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

# Open self-registration — enabled for local `mix phx.server` so a fresh dev
# database is usable without extra setup. Real deployments default this off
# in prod, matching Synapse's `enable_registration: false`; see
# config/runtime.exs.
config :axon_web, :registration, enabled: true

# Fixed convenience value for the shared-secret admin bootstrap
# (`/_synapse/admin/v1/register`), so a fresh dev database can be given an
# admin without extra setup. Prod takes this from REGISTRATION_SHARED_SECRET
# and, if that's unset, disables the endpoint entirely rather than falling
# back to anything — see config/runtime.exs and AxonWeb.AuthController.
config :axon_web, :registration_shared_secret, "complement"

# Remote-media SSRF guard off for local dev only, so a second Axon on this
# machine (127.0.0.1:8448, a loopback address) is still reachable for media
# federation. Prod keeps it on; see AxonFederation.AddressGuard.
config :axon_federation, :allow_private_addresses, true

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
