defmodule AxonWeb.AppService.Client do
  @moduledoc """
  Outbound HTTP calls axon makes *to* an Application Service — the AS's own
  `url` is a plain HTTP(S) endpoint the bridge runs, authenticated with the
  registration's `hs_token` as a bearer token (unlike federation's
  `AxonFederation.HttpClient`, there's no X-Matrix request signing here:
  the shared secret in the registration file is the trust anchor, exactly
  like the shared-secret admin registration bootstrap already uses HMAC
  rather than a signature).

  Spec-defined calls:
    - `push_transaction/3` — `PUT :url/_matrix/app/v1/transactions/:txnId`
    - `query_user/2` — `GET :url/_matrix/app/v1/users/:userId`
    - `query_room_alias/2` — `GET :url/_matrix/app/v1/rooms/:roomAlias`
    - `query_thirdparty_protocol/2`, `query_thirdparty_user/3`,
      `query_thirdparty_location/3` — the "Third party networks" family
      (`GET :url/_matrix/app/v1/thirdparty/{protocol,user,location}...`),
      proxied from `AxonWeb.ThirdPartyController`'s Client-Server API
      surface.
  """

  require Logger

  @doc "Pushes a transaction body. Returns `:ok` or `{:error, reason}`."
  def push_transaction(registration, txn_id, payload) do
    url = "#{registration["url"]}/_matrix/app/v1/transactions/#{txn_id}"

    case request(:put, url, registration["hs_token"], Jason.encode!(payload)) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Asks the AS to lazily provision `user_id`. Per spec the AS is expected to
  have registered the user (via a normal `POST /register` call using its
  own `as_token`) by the time it replies 200. Returns `{:ok, :found}`,
  `{:ok, :not_found}` (AS replied 404 — genuinely doesn't recognize it), or
  `{:error, reason}`.
  """
  def query_user(registration, user_id) do
    url = "#{registration["url"]}/_matrix/app/v1/users/#{encode_path_segment(user_id)}"
    query(registration, url)
  end

  @doc "Same as `query_user/2` but for `GET /_matrix/app/v1/rooms/:roomAlias`."
  def query_room_alias(registration, room_alias) do
    url = "#{registration["url"]}/_matrix/app/v1/rooms/#{encode_path_segment(room_alias)}"
    query(registration, url)
  end

  @doc """
  `GET /_matrix/app/v1/thirdparty/protocol/:protocol` — protocol metadata
  (field types, presets/`instances`, `user_fields`/`location_fields`).
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
  third-party identity does this Matrix user id have). `params` is a map
  of query string fields either way.
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
    case request(:get, url, registration["hs_token"], nil) do
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

  # `URI.encode/1`'s default predicate doesn't escape `#` (or `?`) — fine
  # for a user_id, but a room_alias always starts with `#`, which `URI.parse`
  # (used internally when this URL is later parsed to make the request)
  # treats as the start of a fragment, silently truncating everything from
  # it onward. Escape those two explicitly; leave everything else
  # (`@`, `:`, `!`) as `URI.encode/1` already would, matching how mxids/
  # room_ids appear raw elsewhere in this codebase's federation URLs.
  defp encode_path_segment(value), do: URI.encode(value, &(&1 not in [?#, ??]))

  defp query(registration, url) do
    case request(:get, url, registration["hs_token"], nil) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        {:ok, :found}

      {:ok, %Finch.Response{status: 404}} ->
        {:ok, :not_found}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(method, url, hs_token, body) do
    headers = [{"authorization", "Bearer #{hs_token}"}] ++ content_type(body)
    req = Finch.build(method, url, headers, body)

    case Finch.request(req, Axon.Finch, receive_timeout: 10_000) do
      {:ok, resp} ->
        {:ok, resp}

      {:error, reason} ->
        Logger.warning("AppService HTTP #{method} #{url} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp content_type(nil), do: []
  defp content_type(_body), do: [{"content-type", "application/json"}]
end
