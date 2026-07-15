defmodule AxonWeb.Oidc do
  @moduledoc """
  Delegated OAuth 2.0 / OIDC authentication (MSC3861 + MSC2965 + MSC2964).

  When enabled, Axon does not mint or store its own access tokens. Clients
  authenticate directly against the configured external Authorization
  Server (discovered via `auth_metadata`) and present its token to Axon;
  Axon validates it here via OAuth 2.0 token introspection (RFC 7662) and
  maps the token's `sub`/`username`/`scope` to a local Matrix user + device
  (see `AxonCore.UserStore.authenticate_via_oidc/4`).

  This mirrors how real deployments run: Synapse delegating to Matrix
  Authentication Service, both acting purely as OAuth2 resource servers.
  """

  require Logger

  alias AxonCore.{Repo, UserStore}
  alias AxonCore.Schema.OidcDeviceBinding
  alias AxonWeb.Oidc.Discovery

  @scope_api_regex ~r/^urn:matrix:(?:org\.matrix\.msc2967\.)?client:api:/
  @scope_device_regex ~r/^urn:matrix:(?:org\.matrix\.msc2967\.)?client:device:(.+)$/

  def enabled? do
    config()[:enabled] == true and is_binary(config()[:issuer])
  end

  @doc "Fetches (and caches) the AS's discovery document. `{:ok, map} | {:error, reason}`."
  def metadata do
    if enabled?() do
      Discovery.metadata(config()[:issuer])
    else
      {:error, :disabled}
    end
  end

  @doc """
  Validates `raw_token` against the AS via RFC 7662 introspection and, if
  active, resolves it to a local `{user_id, device_id}`.

  Returns `{:ok, {user_id, device_id}}` or `:error`.
  """
  def introspect(raw_token) do
    with true <- enabled?(),
         {:ok, meta} <- metadata(),
         introspection_endpoint when is_binary(introspection_endpoint) <-
           meta["introspection_endpoint"],
         {:ok, %{"active" => true} = claims} <- do_introspect(introspection_endpoint, raw_token),
         {:ok, device_id} <- extract_device_id(claims, raw_token),
         true <- has_api_scope?(claims),
         localpart when is_binary(localpart) <- extract_localpart(claims) do
      server_name = Application.fetch_env!(:axon_web, :server_name)
      subject = claims["sub"] || localpart

      case UserStore.authenticate_via_oidc(subject, localpart, device_id, server_name) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          Logger.warning("OIDC introspection ok but provisioning failed: #{inspect(reason)}")
          :error
      end
    else
      _ -> :error
    end
  end

  defp do_introspect(introspection_endpoint, raw_token) do
    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"}
    ]

    {headers, body} =
      case config()[:client_auth_method] do
        "client_secret_post" ->
          body =
            URI.encode_query(%{
              "token" => raw_token,
              "token_type_hint" => "access_token",
              "client_id" => config()[:client_id],
              "client_secret" => config()[:client_secret]
            })

          {headers, body}

        _ ->
          creds = Base.encode64("#{config()[:client_id]}:#{config()[:client_secret]}")
          body = URI.encode_query(%{"token" => raw_token, "token_type_hint" => "access_token"})
          {[{"authorization", "Basic #{creds}"} | headers], body}
      end

    req = Finch.build(:post, introspection_endpoint, headers, body)

    case Finch.request(req, Axon.Finch, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: resp_body}} -> Jason.decode(resp_body)
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp has_api_scope?(claims) do
    (claims["scope"] || "")
    |> String.split(" ", trim: true)
    |> Enum.any?(&Regex.match?(@scope_api_regex, &1))
  end

  defp extract_device_id(claims, raw_token) do
    case scope_device_id(claims) do
      device_id when is_binary(device_id) -> {:ok, device_id}
      nil -> {:ok, stable_fallback_device_id(raw_token)}
    end
  end

  defp scope_device_id(claims) do
    (claims["scope"] || "")
    |> String.split(" ", trim: true)
    |> Enum.find_value(fn scope ->
      case Regex.run(@scope_device_regex, scope) do
        [_, device_id] -> device_id
        nil -> nil
      end
    end)
  end

  # No MSC2967 device scope on this token — rather than minting a new random
  # device_id on every request (which would make it impossible for a client
  # to ever hold a coherent device/cross-signing identity), pin one device_id
  # per token by hash, generating it once on first use.
  defp stable_fallback_device_id(raw_token) do
    hash = token_hash(raw_token)

    case Repo.get_by(OidcDeviceBinding, token_hash: hash) do
      %OidcDeviceBinding{device_id: device_id} ->
        device_id

      nil ->
        candidate = generate_device_id()

        Logger.warning(
          "OIDC token introspection response has no urn:matrix:client:device:<id> scope; " <>
            "falling back to a locally-generated stable device_id. The Authorization " <>
            "Server/client should send MSC2967 device scopes."
        )

        %OidcDeviceBinding{}
        |> OidcDeviceBinding.changeset(%{token_hash: hash, device_id: candidate})
        |> Repo.insert(on_conflict: :nothing, conflict_target: :token_hash)

        # Re-read so a concurrent request for the same token resolves to
        # whichever candidate actually won the insert race.
        case Repo.get_by(OidcDeviceBinding, token_hash: hash) do
          %OidcDeviceBinding{device_id: device_id} -> device_id
          nil -> candidate
        end
    end
  end

  defp token_hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  # `username` is the documented fallback claim real ASes (Matrix
  # Authentication Service, Synapse's delegated-auth client) send for the
  # Matrix localpart; fall back to a sanitized `sub` if it's absent.
  defp extract_localpart(claims) do
    claims["username"] || sanitize_localpart(claims["sub"])
  end

  defp sanitize_localpart(nil), do: nil

  defp sanitize_localpart(sub) do
    sub |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9._=\-\/]/, "_")
  end

  defp generate_device_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false) |> String.upcase()
  end

  defp config, do: Application.get_env(:axon_web, :oidc, [])
end
