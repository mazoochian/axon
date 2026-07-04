defmodule AxonWeb.Plug.FederationAuth do
  @moduledoc """
  Verifies the X-Matrix authorization header on inbound federation requests.

  Sets conn.assigns.origin_server on success; halts with 401 on failure.
  Spec: https://spec.matrix.org/v1.18/server-server-api/#request-authentication
  """

  import Plug.Conn
  alias AxonCrypto.{CanonicalJSON, KeyServer}
  alias AxonFederation.KeyCache
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    local_server = KeyServer.server_name()

    case parse_auth_header(conn) do
      {:ok, origin, destination, key_id, sig_b64} ->
        if destination != local_server do
          Logger.warning("FederationAuth: wrong destination #{destination} (expected #{local_server})")
          error(conn, "Wrong destination")
        else
          case verify_signature(conn, origin, destination, key_id, sig_b64) do
            :ok ->
              assign(conn, :origin_server, origin)

            {:error, reason} ->
              Logger.warning("FederationAuth: signature invalid from #{origin}: #{inspect(reason)}")
              error(conn, "Signature verification failed")
          end
        end

      :error ->
        error(conn, "Missing or malformed X-Matrix Authorization header")
    end
  end

  # ---------------------------------------------------------------------------
  # Parse X-Matrix header
  # ---------------------------------------------------------------------------

  # Format: X-Matrix origin="...",destination="...",key="...",sig="..."
  defp parse_auth_header(conn) do
    case get_req_header(conn, "authorization") do
      [auth | _] ->
        if String.starts_with?(auth, "X-Matrix ") do
          rest = String.slice(auth, 9, String.length(auth))

          with {:ok, origin} <- extract_param(rest, "origin"),
               {:ok, destination} <- extract_param(rest, "destination"),
               {:ok, key_id} <- extract_param(rest, "key"),
               {:ok, sig} <- extract_param(rest, "sig") do
            {:ok, origin, destination, key_id, sig}
          else
            _ -> :error
          end
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp extract_param(str, name) do
    case Regex.run(~r/#{name}="([^"]*)"/, str) do
      [_, value] -> {:ok, value}
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # Signature verification
  # ---------------------------------------------------------------------------

  defp verify_signature(conn, origin, destination, key_id, sig_b64) do
    # Re-read body for signing (must have been read by Plug.Parsers already)
    body = read_raw_body(conn)

    content =
      case body do
        "" -> nil
        json -> Jason.decode!(json)
      end

    signable =
      %{
        "method" => conn.method,
        "uri" => full_path(conn),
        "origin" => origin,
        "destination" => destination
      }
      |> then(fn m -> if content, do: Map.put(m, "content", content), else: m end)
      |> CanonicalJSON.encode_to_binary()

    case Base.decode64(sig_b64, padding: false) do
      {:ok, sig_bytes} ->
        pub_key = KeyCache.get_key(origin, key_id)

        if is_nil(pub_key) do
          {:error, :key_not_found}
        else
          if :crypto.verify(:eddsa, :none, signable, sig_bytes, [pub_key, :ed25519]) do
            :ok
          else
            {:error, :invalid_signature}
          end
        end

      :error ->
        {:error, :invalid_sig_encoding}
    end
  end

  defp full_path(conn) do
    case conn.query_string do
      "" -> conn.request_path
      qs -> "#{conn.request_path}?#{qs}"
    end
  end

  defp read_raw_body(conn) do
    # Attempt to read the cached raw body (set by Plug.Parsers with cache_body)
    case conn.assigns[:raw_body] do
      nil ->
        # Fall back to reading from body params if already parsed. Plug.Parsers
        # resolves body_params to `%{}` for EVERY request that passes through
        # it — including bodyless GETs — never leaving it genuinely Unfetched
        # by the time this plug runs. So `body_params == %{}` is ambiguous:
        # it means either "no body was sent at all" (a GET) or "a body was
        # sent and it happened to be the empty JSON object `{}`" (a POST/PUT
        # with an intentionally empty payload) — and per spec those sign
        # differently: "content" is omitted from the signable entirely when
        # there's no body, but included (as {}) when there genuinely is one.
        # A request that actually carried a body always sent a content-type
        # header for it; one that didn't, never does — use that as the
        # disambiguator rather than trusting body_params' emptiness alone.
        has_content_type? = get_req_header(conn, "content-type") != []

        case conn.body_params do
          %Plug.Conn.Unfetched{} -> ""
          params when map_size(params) == 0 and not has_content_type? -> ""
          params -> Jason.encode!(params)
        end

      raw ->
        raw
    end
  end

  # ---------------------------------------------------------------------------
  # Error response
  # ---------------------------------------------------------------------------

  defp error(conn, msg) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{"errcode" => "M_UNAUTHORIZED", "error" => msg}))
    |> halt()
  end
end
