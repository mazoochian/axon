defmodule AxonWeb.IdentityServer do
  @moduledoc """
  Client for the Matrix identity service API
  (https://spec.matrix.org/latest/identity-service-api/) — real
  network calls to whatever identity server a 3pid invite names (either
  the inviting client's own `id_server`/`id_access_token`, or, when the
  client supplies neither, `DEFAULT_IDENTITY_SERVER` — see
  `config/config.exs` and README.md's "Identity server (3pid invites)").

  Covers the three legs `RoomController.invite_3pid/4` needs:

    * `hash_lookup/4` — privacy-preserving hashed lookup (`hash_details`
      then `lookup`) to see whether a 3pid is already bound to a real
      Matrix user ID, so a bound 3pid gets a normal `m.room.member`
      invite instead of a `m.room.third_party_invite`.
    * `store_invite/2` — delegates actual delivery for an *unbound* email
      3pid and hands back the real `public_key`/`public_keys`/
      `key_validity_url`/`display_name`/`token` this server's
      `m.room.third_party_invite` event content must use (rather than
      self-signing with Axon's own key).
    * `request_msisdn_token/2` — starts a real SMS validation session for
      an *unbound* msisdn 3pid. Spec explicitly restricts `store-invite`
      to the `email` medium (there is no msisdn equivalent to delegate
      the invite itself to), so this is as far as identity-server
      delegation for SMS goes; see `RoomController`'s msisdn branch.

  Also provides `pubkey_valid?/2` (the join-time `key_validity_url`
  liveness check — `RoomController.build_join_content/3` calls this
  before honoring a `third_party_signed` proof) and
  `ensure_access_token/2` (the OpenID self-registration fallback used
  when a client invites via `DEFAULT_IDENTITY_SERVER` without its own
  `id_access_token` — see `AxonWeb.OpenidTokens` and
  `AxonWeb.FederationController.openid_userinfo/2`).

  `pubkey_valid?/2` results are cached (same GenServer+ETS shape
  `AxonWeb.Oidc.Discovery` uses for its discovery documents) — a proof
  gets checked at every join attempt against a room's still-live
  `m.room.third_party_invite`, and identity servers don't expect every
  homeserver in a room to re-validate the same ephemeral key on every
  join.
  """

  use GenServer
  require Logger

  @table :axon_identity_server_pubkey_cache
  @ttl_ms :timer.hours(1)
  @timeout 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  # ---------------------------------------------------------------------
  # id_server / id_access_token resolution
  # ---------------------------------------------------------------------

  @doc """
  Resolves the identity server base URL to use: the client's own
  `id_server` param (a bare domain per spec, e.g. `"vector.im"`) if
  given, else the configured `DEFAULT_IDENTITY_SERVER` (already a full
  base URL). `{:error, :missing_id_server}` when neither is available —
  the caller maps that to `M_MISSING_PARAM`, matching Synapse's own
  `"id_server` and `id_access_token` are required when doing 3pid
  invite"` rejection.
  """
  @spec resolve_id_server(map()) :: {:ok, String.t()} | {:error, :missing_id_server}
  def resolve_id_server(params) do
    case params["id_server"] do
      domain when is_binary(domain) and domain != "" ->
        {:ok, normalize_base_url(domain)}

      _ ->
        case Application.get_env(:axon_web, :default_identity_server) do
          url when is_binary(url) and url != "" -> {:ok, normalize_base_url(url)}
          _ -> {:error, :missing_id_server}
        end
    end
  end

  @doc """
  Resolves the identity-server access token to authenticate with: the
  client's own `id_access_token` if given, else a self-registered one
  obtained via the OpenID flow (`ensure_access_token/2`) — only possible
  when `id_server` resolved to `DEFAULT_IDENTITY_SERVER` (a server this
  deployment configured, hence trusts to register a service token with);
  a client-named third-party `id_server` with no client-supplied token
  gets `{:error, :missing_id_access_token}` instead, since axon has no
  business minting tokens against an arbitrary server the client picked.
  """
  @spec resolve_id_access_token(map(), String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def resolve_id_access_token(params, id_server, requester_user_id) do
    default = Application.get_env(:axon_web, :default_identity_server)

    case params["id_access_token"] do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ when is_binary(default) and default != "" ->
        if normalize_base_url(default) == id_server do
          ensure_access_token(id_server, requester_user_id)
        else
          {:error, :missing_id_access_token}
        end

      _ ->
        {:error, :missing_id_access_token}
    end
  end

  defp normalize_base_url(url) do
    if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
      String.trim_trailing(url, "/")
    else
      "https://" <> String.trim_trailing(url, "/")
    end
  end

  # ---------------------------------------------------------------------
  # OpenID self-registration (DEFAULT_IDENTITY_SERVER, no client token)
  # ---------------------------------------------------------------------

  @doc """
  Mints an OpenID token for `user_id` (`AxonWeb.OpenidTokens.issue/1`)
  and exchanges it with the identity server's
  `POST /_matrix/identity/v2/account/register`, which verifies it by
  calling back to this homeserver's own
  `GET /_matrix/federation/v1/openid/userinfo` — the same real
  round trip a client doing this itself would drive, just performed
  server-side. Returns the identity server's own access token.
  """
  @spec ensure_access_token(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_access_token(base_url, user_id) do
    {openid_token, expires_in} = AxonWeb.OpenidTokens.issue(user_id)
    server_name = AxonCrypto.KeyServer.server_name()

    body = %{
      "access_token" => openid_token,
      "token_type" => "Bearer",
      "matrix_server_name" => server_name,
      "expires_in" => expires_in
    }

    case post(base_url <> "/_matrix/identity/v2/account/register", nil, body) do
      {:ok, %{"access_token" => id_access_token}} when is_binary(id_access_token) ->
        {:ok, id_access_token}

      {:ok, %{"token" => id_access_token}} when is_binary(id_access_token) ->
        {:ok, id_access_token}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------
  # Hashed lookup (privacy-preserving; supersedes the deprecated
  # plaintext /_matrix/identity/api/v1/lookup)
  # ---------------------------------------------------------------------

  @doc """
  `GET hash_details` then `POST lookup` for a single `medium`/`address`.
  Returns `{:ok, mxid}` when already bound, `{:ok, nil}` when not, or
  `{:error, reason}` on a network/protocol failure (the caller treats
  that as "proceed as unbound" — a lookup failure shouldn't block an
  invite outright, matching Synapse's own best-effort treatment here).
  """
  @spec hash_lookup(String.t(), String.t() | nil, String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def hash_lookup(base_url, access_token, medium, address) do
    with {:ok, %{"algorithms" => algorithms, "lookup_pepper" => pepper}} <-
           get(base_url <> "/_matrix/identity/v2/hash_details", access_token),
         {:ok, {algorithm, hashed}} <-
           hash_address(algorithms, pepper, medium, address),
         {:ok, %{"mappings" => mappings}} <-
           post(base_url <> "/_matrix/identity/v2/lookup", access_token, %{
             "addresses" => [hashed],
             "algorithm" => algorithm,
             "pepper" => pepper
           }) do
      {:ok, mappings[hashed]}
    end
  end

  defp hash_address(algorithms, pepper, medium, address) do
    cond do
      "sha256" in algorithms ->
        hashed =
          :crypto.hash(:sha256, "#{address} #{medium} #{pepper}")
          |> Base.url_encode64(padding: false)

        {:ok, {"sha256", hashed}}

      "none" in algorithms ->
        {:ok, {"none", "#{address} #{medium}"}}

      true ->
        {:error, :unsupported_hash_algorithm}
    end
  end

  # ---------------------------------------------------------------------
  # store-invite (email only, per spec) / requestToken (msisdn)
  # ---------------------------------------------------------------------

  @doc """
  Delegates delivery of an unbound *email* 3pid invite. Returns the
  identity server's real `token`/`display_name`/`public_keys` — these,
  not axon's own signing key, are what the resulting
  `m.room.third_party_invite` event content must carry.
  """
  @spec store_invite(String.t(), String.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def store_invite(base_url, access_token, params) do
    post(base_url <> "/_matrix/identity/v2/store-invite", access_token, params)
  end

  @doc """
  Starts a real SMS validation session for an unbound msisdn 3pid
  (`POST validate/msisdn/requestToken`). There's no msisdn equivalent of
  `store-invite` to delegate the *invite itself* to (spec restricts that
  to email), so this is only ever a best-effort courtesy call — the
  session it opens isn't consumed anywhere in the invite flow, since
  nothing has bound the number to this pending invite the way an email
  `store-invite` token does. Real and spec-shaped either way: identity
  servers without a configured SMS provider (Sydent's dev default
  included) reject it with a real error, which callers should treat as
  non-fatal.
  """
  @spec request_msisdn_token(String.t(), String.t() | nil, map()) ::
          {:ok, map()} | {:error, term()}
  def request_msisdn_token(base_url, access_token, params) do
    post(base_url <> "/_matrix/identity/v2/validate/msisdn/requestToken", access_token, params)
  end

  # ---------------------------------------------------------------------
  # pubkey liveness (join-time third_party_signed validation)
  # ---------------------------------------------------------------------

  @doc """
  `true` when `key_validity_url` (as stored on the room's
  `m.room.third_party_invite` event — either axon's own
  `/pubkey/isvalid` for a legacy self-signed invite, or the real
  identity server's `/pubkey/isvalid` or `/pubkey/ephemeral/isvalid` for
  a delegated one) reports `public_key` as still valid. Cached for
  `#{div(@ttl_ms, 60_000)} minutes` per `{key_validity_url, public_key}`
  pair. A network/protocol failure is treated as "not currently
  verifiable" (`false`) rather than raised — a join shouldn't hang on a
  slow/unreachable identity server, and `AuthRules`'s own signature
  check already provides the cryptographic guarantee; this is the
  additional revocation check spec recommends on top of it.
  """
  @spec pubkey_valid?(String.t(), String.t()) :: boolean()
  def pubkey_valid?(key_validity_url, public_key) do
    now = System.monotonic_time(:millisecond)
    key = {key_validity_url, public_key}

    case :ets.lookup(@table, key) do
      [{^key, valid?, expires_at}] when expires_at > now ->
        valid?

      _ ->
        GenServer.call(__MODULE__, {:check_pubkey, key_validity_url, public_key}, @timeout + 1000)
    end
  end

  @impl true
  def handle_call({:check_pubkey, key_validity_url, public_key}, _from, state) do
    key = {key_validity_url, public_key}
    now = System.monotonic_time(:millisecond)

    # Re-check the cache: another caller may have already resolved this
    # while we were waiting for the GenServer.
    result =
      case :ets.lookup(@table, key) do
        [{^key, valid?, expires_at}] when expires_at > now ->
          valid?

        _ ->
          valid? = fetch_pubkey_valid?(key_validity_url, public_key)
          :ets.insert(@table, {key, valid?, now + @ttl_ms})
          valid?
      end

    {:reply, result, state}
  end

  defp fetch_pubkey_valid?(key_validity_url, public_key) do
    url = key_validity_url <> "?public_key=" <> URI.encode_www_form(public_key)

    case get(url, nil) do
      {:ok, %{"valid" => true}} -> true
      {:ok, _} -> false
      {:error, reason} ->
        Logger.warning("identity server pubkey validity check failed (#{key_validity_url}): #{inspect(reason)}")
        false
    end
  end

  # ---------------------------------------------------------------------
  # HTTP plumbing
  # ---------------------------------------------------------------------

  defp get(url, access_token) do
    request(:get, url, access_token, nil)
  end

  defp post(url, access_token, body) do
    request(:post, url, access_token, body)
  end

  defp request(method, url, access_token, body) do
    headers =
      [{"accept", "application/json"}] ++
        if(body, do: [{"content-type", "application/json"}], else: []) ++
        if(access_token, do: [{"authorization", "Bearer " <> access_token}], else: [])

    encoded_body = if body, do: Jason.encode!(body), else: nil
    req = Finch.build(method, url, headers, encoded_body)

    case Finch.request(req, Axon.Finch, receive_timeout: @timeout) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        case Jason.decode(resp_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http_error, status, safe_decode(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end
end
