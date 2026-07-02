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

  alias AxonCore.UserStore
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
         introspection_endpoint when is_binary(introspection_endpoint) <- meta["introspection_endpoint"],
         {:ok, %{"active" => true} = claims} <- do_introspect(introspection_endpoint, raw_token),
         {:ok, device_id} <- extract_device_id(claims),
         true <- has_api_scope?(claims),
         localpart when is_binary(localpart) <- extract_localpart(claims) do
      server_name = Application.fetch_env!(:axon_web, :server_name)
      subject = claims["sub"] || localpart

      case UserStore.authenticate_via_oidc(subject, localpart, device_id, server_name) do
        {:ok, result} -> {:ok, result}
        {:error, reason} ->
          Logger.warning("OIDC introspection ok but provisioning failed: #{inspect(reason)}")
          :error
      end
    else
      _ -> :error
    end
  end

  defp do_introspect(introspection_endpoint, raw_token) do
    headers = [{"content-type", "application/x-www-form-urlencoded"}, {"accept", "application/json"}]

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

  defp extract_device_id(claims) do
    device_id =
      (claims["scope"] || "")
      |> String.split(" ", trim: true)
      |> Enum.find_value(fn scope ->
        case Regex.run(@scope_device_regex, scope) do
          [_, device_id] -> device_id
          nil -> nil
        end
      end)

    if device_id, do: {:ok, device_id}, else: {:ok, generate_device_id()}
  end

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
