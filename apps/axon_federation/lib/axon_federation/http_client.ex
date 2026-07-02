defmodule AxonFederation.HttpClient do
  @moduledoc """
  HTTP client for outbound federation requests.

  All requests are signed with the X-Matrix authorization header per the
  Matrix federation spec.
  """

  alias AxonCrypto.{CanonicalJSON, KeyServer}
  require Logger

  @user_agent "Axon/1.0"

  @doc """
  GET request to a remote server's federation endpoint.
  Returns {:ok, body_map} or {:error, reason}.
  """
  def get(server_name, path) do
    url = build_url(server_name, path)
    auth = build_auth_header(server_name, "GET", path, nil)

    req = Finch.build(:get, url, [
      {"authorization", auth},
      {"user-agent", @user_agent},
      {"accept", "application/json"}
    ])

    execute(req)
  end

  @doc """
  PUT request to a remote server's federation endpoint with a JSON body.
  """
  def put(server_name, path, body_map) do
    url = build_url(server_name, path)
    body_json = Jason.encode!(body_map)
    auth = build_auth_header(server_name, "PUT", path, body_map)

    req = Finch.build(:put, url, [
      {"authorization", auth},
      {"content-type", "application/json"},
      {"user-agent", @user_agent}
    ], body_json)

    execute(req)
  end

  @doc """
  POST request to a remote server's federation endpoint with a JSON body.
  """
  def post(server_name, path, body_map) do
    url = build_url(server_name, path)
    body_json = Jason.encode!(body_map)
    auth = build_auth_header(server_name, "POST", path, body_map)

    req = Finch.build(:post, url, [
      {"authorization", auth},
      {"content-type", "application/json"},
      {"user-agent", @user_agent}
    ], body_json)

    execute(req)
  end

  # ---------------------------------------------------------------------------
  # X-Matrix Authorization header
  # ---------------------------------------------------------------------------

  defp build_auth_header(destination, method, path, body) do
    info = KeyServer.server_key_info()
    origin = info.server_name
    key_id = info.key_id

    signable =
      %{
        "method" => method,
        "uri" => path,
        "origin" => origin,
        "destination" => destination
      }
      |> maybe_add_content(body)
      |> CanonicalJSON.encode_to_binary()

    {_, sig_b64} = KeyServer.sign(signable)

    ~s(X-Matrix origin="#{origin}",destination="#{destination}",key="#{key_id}",sig="#{sig_b64}")
  end

  defp maybe_add_content(map, nil), do: map
  defp maybe_add_content(map, body) when is_map(body), do: Map.put(map, "content", body)
  defp maybe_add_content(map, _), do: map

  # ---------------------------------------------------------------------------
  # URL resolution
  # ---------------------------------------------------------------------------

  defp build_url(server_name, path) do
    base = resolve_base_url(server_name)
    base <> path
  end

  defp resolve_base_url(server_name) do
    # Check /.well-known/matrix/server; fall back to :8448
    well_known_url = "https://#{server_name}/.well-known/matrix/server"

    req = Finch.build(:get, well_known_url, [{"user-agent", @user_agent}])

    case Finch.request(req, Axon.Finch, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"m.server" => host}} -> "https://#{host}"
          _ -> "https://#{server_name}:8448"
        end

      _ ->
        "https://#{server_name}:8448"
    end
  rescue
    _ -> "https://#{server_name}:8448"
  end

  # ---------------------------------------------------------------------------
  # Execute + parse
  # ---------------------------------------------------------------------------

  defp execute(req) do
    case Finch.request(req, Axon.Finch, receive_timeout: 30_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %{status: status, body: body}} ->
        reason =
          case Jason.decode(body) do
            {:ok, %{"errcode" => code, "error" => msg}} -> {code, msg}
            _ -> {:http_error, status}
          end

        Logger.warning("Federation HTTP #{status}: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        Logger.warning("Federation HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
