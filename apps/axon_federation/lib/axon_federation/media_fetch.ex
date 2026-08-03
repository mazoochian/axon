defmodule AxonFederation.MediaFetch do
  @moduledoc """
  Fetches another server's media over federation per Matrix 1.11 / MSC3916:
  the authenticated `GET /_matrix/federation/v1/media/{download,thumbnail}`
  endpoints, whose 200 response is `multipart/mixed` with exactly two parts
  (a JSON metadata part, currently always `{}`, then either the media's
  bytes or a `Location` header to redirect to).

  Falls back to the deprecated, unauthenticated `/_matrix/media/v3/...`
  endpoint — with `allow_remote=false`, per spec, so the remote doesn't try
  to recursively proxy it back to us — when the remote's response says it
  doesn't really serve this endpoint:

  - a `404` carrying `M_UNRECOGNIZED`, the spec's defined signal that a
    server hasn't implemented the federation media endpoints yet; or
  - any `400`, which is not spec-mandated as a fallback trigger but is
    what a server whose authenticated-media handler is broken or absent
    tends to answer a perfectly well-formed GET with. Hard-failing the
    user's download over that helps nobody when the deprecated endpoint
    is sitting right there and works. (Complement's own federation test
    double is exactly such a server: `HandleMediaRequests` reuses the
    legacy handler — which validates an `{origin}` path variable — for
    the authenticated route, whose path has no such variable, so it
    unconditionally 400s.)

  Any *other* error is reported as-is rather than masked by a fallback
  attempt: a 403, a 5xx, or a plain 404 without `M_UNRECOGNIZED` all mean
  something specific that a retry against a deprecated endpoint would only
  obscure.
  """

  alias AxonFederation.HttpClient
  require Logger

  @user_agent "Axon/1.0"

  @doc """
  Fetch the original media. Returns `{:ok, content_type, body, filename}`
  (filename is `nil` if the remote didn't supply one via
  `Content-Disposition`) or `{:error, reason}`.
  """
  def download(server_name, media_id) do
    fetch(
      server_name,
      "/_matrix/federation/v1/media/download/#{media_id}",
      fn ->
        legacy_fetch(
          server_name,
          "/_matrix/media/v3/download/#{server_name}/#{media_id}?allow_remote=false"
        )
      end
    )
  end

  @doc "Fetch a thumbnail. Returns `{:ok, content_type, body, filename}` or `{:error, reason}`."
  def thumbnail(server_name, media_id, query) when is_map(query) do
    qs = URI.encode_query(query)

    path =
      "/_matrix/federation/v1/media/thumbnail/#{media_id}" <> if(qs == "", do: "", else: "?#{qs}")

    legacy_qs = URI.encode_query(Map.put(query, "allow_remote", "false"))
    legacy_path = "/_matrix/media/v3/thumbnail/#{server_name}/#{media_id}?#{legacy_qs}"

    fetch(server_name, path, fn -> legacy_fetch(server_name, legacy_path) end)
  end

  # ---------------------------------------------------------------------------

  defp fetch(server_name, path, fallback) do
    case HttpClient.get_raw(server_name, path) do
      {:ok, %{status: 200, headers: headers, body: body}} ->
        parse_multipart(headers, body)

      {:ok, %{status: 404, body: body}} ->
        if unrecognized?(body), do: fallback.(), else: {:error, :not_found}

      {:ok, %{status: 400}} ->
        fallback.()

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unrecognized?(body) do
    case Jason.decode(body) do
      {:ok, %{"errcode" => "M_UNRECOGNIZED"}} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # multipart/mixed parsing
  # ---------------------------------------------------------------------------

  defp parse_multipart(headers, body) do
    with {:ok, boundary} <- content_type_boundary(headers),
         [_json_part, {file_headers, file_body}] <- split_parts(body, boundary) do
      content_type = Map.get(file_headers, "content-type", "application/octet-stream")
      filename = filename_from_content_disposition(file_headers["content-disposition"])

      case Map.get(file_headers, "location") do
        nil -> {:ok, content_type, file_body, filename}
        location -> follow_location(location, filename)
      end
    else
      _ -> {:error, :bad_multipart}
    end
  end

  defp content_type_boundary(headers) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
    |> case do
      {_, v} ->
        case Regex.run(~r/boundary="?([^";]+)"?/, v) do
          [_, boundary] -> {:ok, boundary}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # Splits on the boundary marker and drops the leading preamble ("", before
  # the first marker) and the trailing "--\r\n" epilogue (after the final
  # one) by position, not by blanket-trimming each chunk — a part with an
  # empty body (e.g. a Location-redirect part with no inline bytes) has
  # nothing *but* the CRLFs that delimit it, and `String.trim/1` would eat
  # the blank-line header/body separator right along with them.
  defp split_parts(body, boundary) do
    pieces = String.split(body, "--" <> boundary)

    pieces
    |> Enum.slice(1..(length(pieces) - 2)//1)
    |> Enum.map(&strip_boundary_crlf/1)
    |> Enum.map(&parse_part/1)
  end

  defp strip_boundary_crlf(chunk) do
    chunk
    |> strip_prefix_crlf()
    |> strip_suffix_crlf()
  end

  defp strip_prefix_crlf("\r\n" <> rest), do: rest
  defp strip_prefix_crlf("\n" <> rest), do: rest
  defp strip_prefix_crlf(other), do: other

  defp strip_suffix_crlf(chunk) do
    cond do
      String.ends_with?(chunk, "\r\n") -> binary_part(chunk, 0, byte_size(chunk) - 2)
      String.ends_with?(chunk, "\n") -> binary_part(chunk, 0, byte_size(chunk) - 1)
      true -> chunk
    end
  end

  defp parse_part(raw) do
    case String.split(raw, ~r/\r?\n\r?\n/, parts: 2) do
      [headers_block, content] -> {parse_headers(headers_block), content}
      _ -> {%{}, ""}
    end
  end

  defp parse_headers(block) do
    block
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [k, v] -> Map.put(acc, k |> String.trim() |> String.downcase(), String.trim(v))
        _ -> acc
      end
    end)
  end

  # Per spec: "the remote server's filename in the Content-Disposition
  # header is used as the filename instead" — extracts it from either the
  # RFC 6266 extended form (filename*=UTF-8''<pct-encoded>, preferred,
  # required for non-ASCII names) or the plain quoted-string form.
  defp filename_from_content_disposition(nil), do: nil

  defp filename_from_content_disposition(value) do
    cond do
      m = Regex.run(~r/filename\*\s*=\s*UTF-8''([^;]+)/i, value) ->
        m |> Enum.at(1) |> URI.decode()

      m = Regex.run(~r/filename\s*=\s*"((?:[^"\\]|\\.)*)"/i, value) ->
        m |> Enum.at(1) |> String.replace(~r/\\(.)/, "\\1")

      m = Regex.run(~r/filename\s*=\s*([^;]+)/i, value) ->
        m |> Enum.at(1) |> String.trim()

      true ->
        nil
    end
  end

  # Per spec: "servers SHOULD NOT cache the URL" — always re-fetched, no
  # X-Matrix auth added (it's a plain URL the remote handed us, not one of
  # its own federation endpoints). `filename` is the one already parsed
  # from the multipart file part's own Content-Disposition — the redirect
  # target's response isn't required to (and by spec, need not) repeat it.
  defp follow_location(url, filename) do
    req = Finch.build(:get, url, [{"user-agent", @user_agent}])

    case Finch.request(req, Axon.Finch, receive_timeout: 30_000) do
      {:ok, %{status: 200, headers: headers, body: body}} ->
        content_type =
          headers
          |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
          |> case do
            {_, v} -> v
            nil -> "application/octet-stream"
          end

        {:ok, content_type, body, filename}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Legacy fallback (deprecated, unauthenticated /_matrix/media/v3/...)
  # ---------------------------------------------------------------------------

  defp legacy_fetch(server_name, path_with_query) do
    base = AxonFederation.ServerResolver.resolve(server_name)
    req = Finch.build(:get, base <> path_with_query, [{"user-agent", @user_agent}])

    case Finch.request(req, Axon.Finch, receive_timeout: 30_000) do
      {:ok, %{status: 200, headers: headers, body: body}} ->
        content_type =
          headers
          |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
          |> case do
            {_, v} -> v
            nil -> "application/octet-stream"
          end

        filename =
          headers
          |> Enum.find(fn {k, _} -> String.downcase(k) == "content-disposition" end)
          |> case do
            {_, v} -> filename_from_content_disposition(v)
            nil -> nil
          end

        {:ok, content_type, body, filename}

      {:ok, %{status: status}} when status in [403, 404] ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning(
          "Legacy remote media fetch failed for #{path_with_query}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
