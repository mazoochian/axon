defmodule AxonWeb.AppService.Client do
  @moduledoc """
  The *query* half of axon's outbound HTTP to an Application Service: calls
  where axon asks a bridge a question and needs its answer back, as opposed
  to `AxonWeb.AppService.Manager`'s fire-and-forget transaction push (which
  keeps its own delivery code, since it has no response body to decode and
  is driven by PubSub rather than by a waiting client request).

  Only the "Third party networks" family lives here so far — the three
  `GET :url/_matrix/app/v1/thirdparty/...` endpoints backing
  `AxonWeb.ThirdPartyController`'s Client-Server API surface.

  Authentication is the registration's `hs_token` as a bearer token. Unlike
  federation's `AxonFederation.HttpClient` there's no X-Matrix request
  signing: the shared secret in the registration file is the trust anchor,
  the same way the shared-secret admin registration bootstrap uses an HMAC
  rather than a signature.
  """

  require Logger

  @doc """
  `GET /_matrix/app/v1/thirdparty/protocol/:protocol` — protocol metadata
  (`field_types`, `instances`, `user_fields`/`location_fields`, `icon`).
  Returns `{:ok, decoded_body}` or `{:error, reason}` (including
  `{:error, :not_found}` on a 404).
  """
  def query_thirdparty_protocol(registration, protocol) do
    url =
      "#{registration["url"]}/_matrix/app/v1/thirdparty/protocol/#{encode_path_segment(protocol)}"

    query_json(registration, url)
  end

  @doc """
  Third-party user lookup. With `protocol`, hits
  `GET .../thirdparty/user/:protocol?field=value...` (find Matrix user ids
  matching third-party search fields); without, hits
  `GET .../thirdparty/user?userid=...` (the reverse direction — what
  third-party identity does this Matrix user id have). `params` is a map of
  query-string fields either way.
  """
  def query_thirdparty_user(registration, protocol, params) do
    path = if protocol, do: "user/#{encode_path_segment(protocol)}", else: "user"
    url = "#{registration["url"]}/_matrix/app/v1/thirdparty/#{path}?#{URI.encode_query(params)}"
    query_json(registration, url)
  end

  @doc "Same as `query_thirdparty_user/3` but for `.../thirdparty/location[/:protocol]`."
  def query_thirdparty_location(registration, protocol, params) do
    path = if protocol, do: "location/#{encode_path_segment(protocol)}", else: "location"
    url = "#{registration["url"]}/_matrix/app/v1/thirdparty/#{path}?#{URI.encode_query(params)}"
    query_json(registration, url)
  end

  defp query_json(registration, url) do
    case request(:get, url, registration["hs_token"]) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %Finch.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `value` is attacker-influenced (a client picks the `:protocol` in the
  # URL, already `URI.decode`d by Phoenix's router) and gets spliced
  # straight into the outbound URL below, so it must be encoded down to the
  # unreserved character set — anything else (`/`, `#`, `?`, space, ...)
  # gets percent-escaped rather than left to be reinterpreted as a path or
  # query separator, which would otherwise let a segment like `../../admin`
  # redirect the outbound request to an unintended path on the AS.
  defp encode_path_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp request(method, url, hs_token) do
    req = Finch.build(method, url, [{"authorization", "Bearer #{hs_token}"}])

    case Finch.request(req, Axon.Finch, receive_timeout: 10_000) do
      {:ok, resp} ->
        {:ok, resp}

      {:error, reason} ->
        Logger.warning("AppService HTTP #{method} #{url} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
