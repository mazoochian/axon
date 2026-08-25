defmodule AxonMedia.UrlPreview do
  @moduledoc """
  SSRF-hardened URL preview fetching (OpenGraph-ish metadata extraction)
  for `GET /_matrix/client/v1/media/preview_url`, previously a deliberate
  404 (see README "Known gaps") rather than a naive unprotected fetch.

  Defense in depth against SSRF:
    - scheme allowlist (http/https only)
    - literal-IP hosts checked directly; hostname-based URLs are resolved
      and *every* returned address is checked, against private/loopback/
      link-local/multicast/reserved ranges (IPv4 and IPv6, including
      IPv4-mapped IPv6)
    - redirects are followed manually (capped at #{inspect(3)} hops) with
      the same validation re-applied to every hop, rather than letting the
      HTTP client silently follow a redirect into a blocked address
    - response size and total time are capped
    - the connection is pinned to the exact address that was validated
      (see "DNS rebinding" below) — connects a raw `Mint.HTTP` socket to
      that literal address rather than handing the hostname to an HTTP
      client that would resolve it a second time

  ## DNS rebinding

  A naive validate-then-fetch split has a TOCTOU gap: validate the
  hostname's DNS answer, then hand the same hostname to an HTTP client,
  which resolves it *again* to actually connect — a rebinding attacker
  (short TTL, or a DNS server that alternates answers) can return a public
  address for the validation lookup and a private one for the client's own
  lookup a moment later. Closed here by resolving once, validating that
  answer, and connecting directly to that literal address (`Mint.HTTP.connect/4`
  with `address` set to the validated IP tuple and `hostname:` set
  separately for the `Host` header, TLS SNI, and certificate hostname
  verification) — there is no second resolution for an attacker to win a
  race against.
  """

  require Logger
  import Ecto.Query, only: [from: 2]
  import Bitwise
  alias AxonCore.Repo
  alias AxonMedia.Store

  @max_body_bytes 5 * 1024 * 1024
  @max_redirects 3
  @fetch_timeout 10_000
  @cache_ttl_seconds 3600

  @doc """
  Returns `{:ok, og_data}` (a map of "og:..." keys per spec, `og:image`
  rehosted as a local `mxc://` URI if present) or `{:error, reason}`.
  `server_name` is used only to mint the `mxc://` URI for a rehosted image.
  """
  def fetch(url, server_name) do
    case cached(url) do
      {:ok, data} ->
        {:ok, data}

      :miss ->
        with {:ok, data} <- fetch_and_parse(url, @max_redirects, server_name) do
          cache_put(url, data)
          {:ok, data}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Cache
  # ---------------------------------------------------------------------------

  defp cached(url) do
    cutoff = DateTime.add(DateTime.utc_now(), -@cache_ttl_seconds, :second)

    case Repo.one(
           from(p in "url_previews",
             where: p.url == ^url and p.fetched_at > ^cutoff,
             select: p.data
           )
         ) do
      nil -> :miss
      data -> {:ok, data}
    end
  end

  defp cache_put(url, data) do
    Repo.insert_all(
      "url_previews",
      [%{url: url, data: data, fetched_at: DateTime.utc_now(:microsecond)}],
      on_conflict: {:replace, [:data, :fetched_at]},
      conflict_target: [:url]
    )
  end

  # ---------------------------------------------------------------------------
  # Fetch + redirect handling
  # ---------------------------------------------------------------------------

  defp fetch_and_parse(_url, 0, _server_name), do: {:error, :too_many_redirects}

  defp fetch_and_parse(url, redirects_left, server_name) do
    with {:ok, address} <- validate_url(url),
         {:ok, status, headers, body} <- http_get(url, address) do
      cond do
        status in 300..399 ->
          case find_header(headers, "location") do
            nil ->
              {:error, :bad_redirect}

            location ->
              fetch_and_parse(resolve_redirect(url, location), redirects_left - 1, server_name)
          end

        status in 200..299 ->
          content_type = find_header(headers, "content-type") || ""
          parse_body(content_type, body, server_name, url)

        true ->
          {:error, {:http_status, status}}
      end
    end
  end

  defp resolve_redirect(base_url, location) do
    base_url
    |> URI.parse()
    |> URI.merge(location)
    |> URI.to_string()
  end

  defp parse_body(content_type, body, server_name, page_url) do
    cond do
      String.starts_with?(content_type, "text/html") ->
        {:ok, extract_og(body, server_name, page_url)}

      String.starts_with?(content_type, "image/") ->
        {:ok, rehost_image(body, content_type, server_name)}

      true ->
        {:ok, %{}}
    end
  end

  # ---------------------------------------------------------------------------
  # HTML/OpenGraph extraction (regex-based — no HTML parser dependency;
  # good enough for the handful of meta tags this cares about)
  # ---------------------------------------------------------------------------

  @doc "Extracts og:title/description/site_name/type/url/image from an HTML document. `page_url`, when given, resolves an `og:image` that's a relative reference (common in the wild despite the OG spec requiring absolute URLs) against the page it came from. Public for direct unit testing of the parsing logic, independent of the SSRF-gated fetch."
  def extract_og(html, server_name \\ nil, page_url \\ nil) do
    base =
      %{}
      |> maybe_put_meta(html, "og:title", "title")
      |> maybe_put_meta(html, "og:description", "description")
      |> maybe_put_meta(html, "og:site_name", "site_name")
      |> maybe_put_meta(html, "og:type", "type")
      |> maybe_put_meta(html, "og:url", "url")

    base =
      if not Map.has_key?(base, "og:title") do
        case Regex.run(~r/<title[^>]*>([^<]*)<\/title>/i, html) do
          [_, title] -> Map.put(base, "og:title", String.trim(title))
          _ -> base
        end
      else
        base
      end

    case find_meta(html, "og:image") do
      nil ->
        base

      image_url ->
        resolved_image_url =
          if page_url, do: resolve_redirect(page_url, image_url), else: image_url

        case fetch(resolved_image_url, server_name) do
          {:ok, %{"__image__" => image_map}} -> Map.merge(base, image_map)
          _ -> base
        end
    end
  end

  defp maybe_put_meta(acc, html, og_key, out_key) do
    case find_meta(html, og_key) do
      nil -> acc
      value -> Map.put(acc, "og:#{out_key}", value)
    end
  end

  defp maybe_put_meta_exact(acc, html, og_key, out_key) do
    case find_meta(html, og_key) do
      nil -> acc
      value -> Map.put(acc, out_key, value)
    end
  end

  defp find_meta(html, property) do
    pattern =
      ~r/<meta[^>]+(?:property|name)=["']#{Regex.escape(property)}["'][^>]+content=["']([^"']*)["']/i

    case Regex.run(pattern, html) do
      [_, value] -> html_unescape(value)
      _ -> nil
    end
  end

  defp html_unescape(s) do
    s
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp rehost_image(body, content_type, server_name) do
    case Store.upload("url_preview", content_type, body, server_name) do
      {:ok, media_id} ->
        dimensions = get_image_dimensions(body, content_type)
        %{
          "__image__" => %{
            "og:image" => "mxc://#{server_name}/#{media_id}",
            "matrix:image:size" => byte_size(body),
            "og:image:width" => dimensions[:width],
            "og:image:height" => dimensions[:height]
          }
        }

      {:error, _} ->
        %{}
    end
  end

  @doc "Parses width/height out of raw image bytes, by `content_type`. Public for direct unit testing against real fixture bytes, independent of the SSRF-gated fetch."
  def get_image_dimensions(body, content_type) do
    case content_type do
      "image/png" -> get_png_dimensions(body)
      "image/jpeg" -> get_jpeg_dimensions(body)
      "image/gif" -> get_gif_dimensions(body)
      "image/webp" -> get_webp_dimensions(body)
      _ -> %{width: 0, height: 0}
    end
  end

  defp get_png_dimensions(body) do
    # PNG: 8-byte signature + 4-byte IHDR length + 4-byte "IHDR" type, then
    # width/height at bytes 16-23 (4 bytes each, big-endian).
    <<_::binary-size(16), width::32, height::32, _::binary>> = body
    %{width: width, height: height}
  end

  defp get_jpeg_dimensions(body) do
    # JPEG: scan for SOF markers (0xFFC0-0xFFCF except 0xFFC4, 0xFFC8, 0xFFCC)
    # After marker: 2 bytes length, 1 byte precision, 2 bytes height, 2 bytes width
    get_jpeg_dimensions(body, 0)
  end

  defp get_jpeg_dimensions(<<0xFF, marker, length::16, 0x08, height::16, width::16, _::binary>>, _offset) when marker in [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF] do
    %{width: width, height: height}
  end

  defp get_jpeg_dimensions(<<0xFF, marker, length::16, rest::binary>>, offset) when marker in [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF] do
    # This is a SOF marker but we couldn't match the pattern, skip it
    skip = length - 2
    <<_::binary-size(skip), rest2::binary>> = rest
    get_jpeg_dimensions(rest2, offset + 2 + length)
  end

  defp get_jpeg_dimensions(<<0xFF, marker, length::16, rest::binary>>, offset) when marker >= 0xD0 and marker <= 0xD9 do
    # RST markers (0xD0-0xD7) and EOI (0xD9) have no length field
    get_jpeg_dimensions(rest, offset + 2)
  end

  defp get_jpeg_dimensions(<<0xFF, marker, length::16, rest::binary>>, offset) do
    # Other markers have length field, skip payload
    skip = length - 2
    <<_::binary-size(skip), rest2::binary>> = rest
    get_jpeg_dimensions(rest2, offset + 2 + length)
  end

  defp get_jpeg_dimensions(<<_::1, rest::binary>>, offset) do
    get_jpeg_dimensions(rest, offset + 1)
  end

  defp get_jpeg_dimensions(<<>>, _offset) do
    %{width: 0, height: 0}
  end

  defp get_gif_dimensions(body) do
    # GIF: width/height at bytes 6-9 (2 bytes each, little-endian)
    <<_::6, width::16-little, height::16-little, _::binary>> = body
    %{width: width, height: height}
  end

  defp get_webp_dimensions(body) do
    # WebP: VP8/VP8L chunk after RIFF header
    # RIFF: "RIFF" (4), file_size (4), "WEBP" (4)
    # Then VP8: "VP8 " (4), chunk_size (4), then 10 bytes header with width/height
    # Or VP8L: "VP8L" (4), chunk_size (4), then 1 byte signature + width/height (14 bits each)
    get_webp_dimensions(body, 0)
  end

  defp get_webp_dimensions(<<0x52, 0x49, 0x46, 0x46, _file_size::32, 0x57, 0x45, 0x42, 0x50, 0x38, 0x20, _chunk_size::32, _::8, width::24-little, height::24-little, _::binary>>, _offset) do
    # VP8 (lossy) format
    %{width: width, height: height}
  end

  defp get_webp_dimensions(<<0x52, 0x49, 0x46, 0x46, _file_size::32, 0x57, 0x45, 0x42, 0x50, 0x38, 0x4C, _chunk_size::32, _::8, width_bits::14-little, height_bits::14-little, _::binary>>, _offset) do
    # VP8L (lossless) format
    %{width: width_bits, height: height_bits}
  end

  defp get_webp_dimensions(<<_::1, rest::binary>>, offset) when offset < 100 do
    get_webp_dimensions(rest, offset + 1)
  end

  defp get_webp_dimensions(_body, _offset) do
    %{width: 0, height: 0}
  end

  # ---------------------------------------------------------------------------
  # SSRF validation
  # ---------------------------------------------------------------------------

  # Returns {:ok, address} — the single literal address the actual
  # connection must be pinned to (see moduledoc "DNS rebinding"), not just
  # `:ok`. Still blocks if *any* resolved address is private, not only the
  # one we'd pin to: an attacker-controlled resolver returning a mix of
  # public/private answers for one hostname is itself a red flag worth
  # rejecting outright, even though pinning alone would already prevent
  # the private one from ever being dialed.
  defp validate_url(url) do
    with %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(url),
         {:ok, addresses} <- resolve(host),
         false <- private_addresses_blocked?() and Enum.any?(addresses, &private_address?/1) do
      {:ok, hd(addresses)}
    else
      %URI{} -> {:error, :invalid_url}
      {:error, _} = err -> err
      true -> {:error, :blocked_address}
    end
  end

  # Off only for the Complement test harness (complement/start.sh sets
  # URL_PREVIEW_ALLOW_PRIVATE_ADDRESSES, consumed in config/runtime.exs) —
  # Complement's own test webserver is only reachable via the Docker host
  # gateway, which is itself a private address. Every real deployment keeps
  # this on; there's no equivalent knob wired up for a real admin to flip.
  defp private_addresses_blocked? do
    not Application.get_env(:axon_media, :url_preview_allow_private_addresses, false)
  end

  defp resolve(host) do
    host_charlist = String.to_charlist(host)

    case :inet.parse_address(host_charlist) do
      {:ok, ip} ->
        {:ok, [ip]}

      {:error, :einval} ->
        case :inet.getaddrs(host_charlist, :inet) do
          {:ok, v4} -> {:ok, v4 ++ resolve_v6(host_charlist)}
          {:error, _} -> resolve_v6_only(host_charlist)
        end
    end
  end

  defp resolve_v6(host_charlist) do
    case :inet.getaddrs(host_charlist, :inet6) do
      {:ok, v6} -> v6
      {:error, _} -> []
    end
  end

  defp resolve_v6_only(host_charlist) do
    case :inet.getaddrs(host_charlist, :inet6) do
      {:ok, v6} -> {:ok, v6}
      {:error, reason} -> {:error, {:dns_failed, reason}}
    end
  end

  # IPv4 private/reserved ranges: 10/8, 172.16/12, 192.168/16, 127/8
  # (loopback), 169.254/16 (link-local, incl. cloud metadata), 0/8, 100.64/10
  # (CGNAT), 224/4 (multicast), 240/4 (reserved).
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({127, _, _, _}), do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({0, _, _, _}), do: true
  defp private_address?({a, b, _, _}) when a == 172 and b in 16..31, do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({100, b, _, _}) when b in 64..127, do: true
  defp private_address?({a, _, _, _}) when a >= 224, do: true
  # IPv6: ::1 loopback, fe80::/10 link-local, fc00::/7 unique-local, ::/128.
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when (a &&& 0xFFC0) == 0xFE80, do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: true
  # IPv4-mapped IPv6 (::ffff:a.b.c.d) — unwrap and re-check as IPv4.
  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    private_address?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})
  end

  defp private_address?(_), do: false

  import Bitwise

  # ---------------------------------------------------------------------------
  # HTTP fetch (size + time capped)
  # ---------------------------------------------------------------------------

  # Connects directly to `address` (the literal IP validate_url/1 already
  # checked) rather than to `url`'s hostname — closes the DNS-rebinding gap
  # documented in the moduledoc. `hostname:` still carries the original
  # host for the Host header, TLS SNI, and certificate hostname
  # verification, so a normal https:// preview of a virtual-hosted site
  # still works correctly.
  defp http_get(url, address) do
    uri = URI.parse(url)
    scheme = String.to_existing_atom(uri.scheme)
    port = uri.port || default_port(scheme)
    path = request_path(uri)

    connect_opts = [hostname: uri.host, transport_opts: [timeout: @fetch_timeout]]

    with {:ok, conn} <- Mint.HTTP.connect(scheme, address, port, connect_opts),
         {:ok, conn, ref} <-
           Mint.HTTP.request(conn, "GET", path, [{"user-agent", "axon-url-preview/1.0"}], nil) do
      deadline = System.monotonic_time(:millisecond) + @fetch_timeout
      acc = %{status: nil, headers: [], body: <<>>, done: false, error: nil}
      result = receive_response(conn, ref, acc, deadline)
      Mint.HTTP.close(conn)
      result
    else
      {:error, reason} ->
        Logger.warning("URL preview fetch failed for #{url}: #{inspect(reason)}")
        {:error, :fetch_failed}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        Logger.warning("URL preview fetch failed for #{url}: #{inspect(reason)}")
        {:error, :fetch_failed}
    end
  end

  defp request_path(%URI{path: path, query: query}) do
    base = path || "/"
    if query, do: base <> "?" <> query, else: base
  end

  defp default_port(:https), do: 443
  defp default_port(:http), do: 80

  defp receive_response(conn, ref, acc, deadline_ms) do
    cond do
      byte_size(acc.body) > @max_body_bytes ->
        {:error, :response_too_large}

      acc.error ->
        {:error, acc.error}

      acc.done ->
        {:ok, acc.status, acc.headers, acc.body}

      true ->
        timeout = max(deadline_ms - System.monotonic_time(:millisecond), 0)

        receive do
          message ->
            case Mint.HTTP.stream(conn, message) do
              {:ok, conn, responses} ->
                receive_response(
                  conn,
                  ref,
                  Enum.reduce(responses, acc, &apply_response(&1, &2, ref)),
                  deadline_ms
                )

              {:error, _conn, reason, _responses} ->
                {:error, reason}

              :unknown ->
                receive_response(conn, ref, acc, deadline_ms)
            end
        after
          timeout -> {:error, :timeout}
        end
    end
  end

  defp apply_response({:status, ref, status}, acc, ref), do: %{acc | status: status}

  defp apply_response({:headers, ref, headers}, acc, ref),
    do: %{acc | headers: acc.headers ++ headers}

  defp apply_response({:data, ref, data}, acc, ref), do: %{acc | body: acc.body <> data}
  defp apply_response({:done, ref}, acc, ref), do: %{acc | done: true}
  defp apply_response({:error, ref, reason}, acc, ref), do: %{acc | error: reason}
  defp apply_response(_other, acc, _ref), do: acc

  defp find_header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end
end
