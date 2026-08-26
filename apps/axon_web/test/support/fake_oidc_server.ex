defmodule AxonWeb.FakeOidcServer do
  @moduledoc """
  A minimal in-process Authorization Server standing in for a real OIDC
  provider (Keycloak/Dex/Authelia/MAS) in tests: serves the discovery
  document and an RFC 7662 introspection endpoint. Lets us test Axon's
  delegated-auth (MSC3861) resource-server code — discovery caching,
  introspection request shape, scope/username extraction, auto-provisioning
  — against a real HTTP round trip without depending on any external service.
  """

  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
  plug(:dispatch)

  @valid_token "fake-as-valid-token"
  @valid_token_no_device_scope "fake-as-valid-token-no-device-scope"
  @valid_token_bad_username "fake-as-valid-token-bad-username"
  @valid_token_mixed_case_username "fake-as-valid-token-mixed-case-username"
  @valid_token_empty_sub_dave "fake-as-valid-token-empty-sub-dave"
  @valid_token_empty_sub_erin "fake-as-valid-token-empty-sub-erin"

  def valid_token, do: @valid_token

  @doc """
  A token whose introspection response has no urn:matrix:client:device:<id>
  scope, as a real AS/client pairing that hasn't implemented MSC2967 device
  scopes yet would return. Used to exercise Axon's stable-fallback device_id
  behavior in AxonWeb.Oidc.
  """
  def valid_token_no_device_scope, do: @valid_token_no_device_scope

  @doc """
  A token whose `username` claim is not a legal Matrix localpart — a full
  user ID, complete with `@` and `:`. A misconfigured Authorization Server
  (or one that lets a user set their own `username`) can send anything at
  all here, and Axon used to take it verbatim as the localpart while
  `/register` would have refused the identical string.
  """
  def valid_token_bad_username, do: @valid_token_bad_username

  @doc "A token whose `username` claim is legal but mixed-case."
  def valid_token_mixed_case_username, do: @valid_token_mixed_case_username

  @doc """
  Two distinct tokens whose introspection responses both carry `"sub": ""`
  (a misbehaving AS, or one omitting `sub` and getting a JSON default back)
  with different `username`s — `""` is truthy in Elixir, so `subject ||
  localpart` used to accept it as a real subject, collapsing every such
  token onto the same shared `oidc_subject: ""` account regardless of who
  it actually belonged to.
  """
  def valid_token_empty_sub_dave, do: @valid_token_empty_sub_dave
  def valid_token_empty_sub_erin, do: @valid_token_empty_sub_erin

  def child_spec(opts) do
    port = Keyword.fetch!(opts, :port)

    %{
      id: {__MODULE__, port},
      start: {Bandit, :start_link, [[plug: __MODULE__, ip: {127, 0, 0, 1}, port: port]]}
    }
  end

  get "/.well-known/openid-configuration" do
    issuer = "http://127.0.0.1:#{conn.port}"

    json(conn, %{
      "issuer" => issuer,
      "authorization_endpoint" => "#{issuer}/authorize",
      "token_endpoint" => "#{issuer}/token",
      "introspection_endpoint" => "#{issuer}/introspect",
      "revocation_endpoint" => "#{issuer}/revoke",
      "registration_endpoint" => "#{issuer}/register",
      "jwks_uri" => "#{issuer}/jwks",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "response_modes_supported" => ["query", "fragment"],
      "code_challenge_methods_supported" => ["S256"]
    })
  end

  post "/introspect" do
    case conn.body_params["token"] do
      @valid_token ->
        json(conn, %{
          "active" => true,
          "sub" => "oidc-subject-abc123",
          "username" => "alice_oidc",
          "scope" =>
            "urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:OIDCDEV1"
        })

      @valid_token_no_device_scope ->
        json(conn, %{
          "active" => true,
          "sub" => "oidc-subject-nodevice",
          "username" => "bob_oidc",
          "scope" => "urn:matrix:org.matrix.msc2967.client:api:*"
        })

      @valid_token_bad_username ->
        json(conn, %{
          "active" => true,
          "sub" => "oidc-subject-hostile",
          "username" => "@server.notices:localhost",
          "scope" =>
            "urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:OIDCDEV2"
        })

      @valid_token_mixed_case_username ->
        json(conn, %{
          "active" => true,
          "sub" => "oidc-subject-mixedcase",
          "username" => "Carol_OIDC",
          "scope" =>
            "urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:OIDCDEV3"
        })

      @valid_token_empty_sub_dave ->
        json(conn, %{
          "active" => true,
          "sub" => "",
          "username" => "dave_oidc",
          "scope" => "urn:matrix:org.matrix.msc2967.client:api:*"
        })

      @valid_token_empty_sub_erin ->
        json(conn, %{
          "active" => true,
          "sub" => "",
          "username" => "erin_oidc",
          "scope" => "urn:matrix:org.matrix.msc2967.client:api:*"
        })

      _ ->
        json(conn, %{"active" => false})
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp json(conn, data) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(data))
  end
end
