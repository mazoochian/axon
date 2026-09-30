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
    - redirects are followed manually (capped at 3 hops) with
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
  import Bitwise
  import Ecto.Query, only: [from: 2]
  import AxonCore.MapUtil, only: [maybe_put: 3]
  alias AxonCore.{NetworkAddress, Repo}
  alias AxonMedia.Store

  @max_body_bytes 5 * 1024 * 1024
  @max_redirects 3
  @fetch_timeout 10_000
  @cache_ttl_seconds 3600
  @image_keys ~w(og:image matrix:image:size og:image:width og:image:height)

  @doc """
  Returns `{:ok, og_data}` (a map of "og:..." keys per spec, `og:image`
  rehosted as a local `mxc://` URI if present) or `{:error, reason}`.
  `server_name` is used only to mint the `mxc://` URI for a rehosted image.
  """
  def fetch(url, server_name) do
    with_cache(url, fn -> fetch_and_parse(url, server_name) end)
  end

  # og:image is fetched through this image-only path: it never parses HTML,
  # so a page whose og:image points back at itself (or at another page)
  # can't recurse.
  defp fetch_image(url, server_name) do
    case with_cache(url, fn -> fetch_and_rehost_image(url, server_name) end) do
      {:ok, %{"og:image" => "mxc://" <> _} = data} -> {:ok, Map.take(data, @image_keys)}
      {:ok, _} -> {:error, :not_an_image}
      err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Cache
  # ---------------------------------------------------------------------------

  defp with_cache(url, fun) do
    case cached(url) do
      {:ok, data} ->
        {:ok, data}

      :miss ->
        with {:ok, data} <- fun.() do
          cache_put(url, data)
          {:ok, data}
        end
    end
  end

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

  defp fetch_and_parse(url, server_name) do
    with {:ok, content_type, body, final_url} <- get_following_redirects(url, @max_redirects) do
      cond do
        content_type == "text/html" -> {:ok, extract_og(body, server_name, final_url)}
        image_type?(content_type) -> {:ok, rehost_image(body, content_type, server_name)}
        true -> {:ok, %{}}
      end
    end
  end

  defp fetch_and_rehost_image(url, server_name) do
    with {:ok, content_type, body, _final_url} <- get_following_redirects(url, @max_redirects) do
      if image_type?(content_type) do
        {:ok, rehost_image(body, content_type, server_name)}
      else
        {:error, :not_an_image}
      end
    end
  end

  defp image_type?(content_type), do: String.starts_with?(content_type, "image/")

  defp get_following_redirects(url, redirects_left) do
    with {:ok, address} <- validate_url(url),
         {:ok, status, headers, body} <- http_get(url, address) do
      cond do
        status in 300..399 ->
          case find_header(headers, "location") do
            nil -> {:error, :bad_redirect}
            _ when redirects_left == 0 -> {:error, :too_many_redirects}
            location -> get_following_redirects(resolve_url(url, location), redirects_left - 1)
          end

        status in 200..299 ->
          {:ok, base_content_type(find_header(headers, "content-type")), body, url}

        true ->
          {:error, {:http_status, status}}
      end
    end
  end

  defp base_content_type(nil), do: ""

  defp base_content_type(value),
    do: value |> String.split(";") |> hd() |> String.trim() |> String.downcase()

  defp resolve_url(base_url, location) do
    base_url
    |> URI.parse()
    |> URI.merge(location)
    |> URI.to_string()
  end

  # ---------------------------------------------------------------------------
  # HTML/OpenGraph extraction (regex-based — no HTML parser dependency;
  # good enough for the handful of meta tags this cares about)
  # ---------------------------------------------------------------------------

  @doc "Extracts og:title/description/site_name/type/url/image from an HTML document. `page_url`, when given, resolves an `og:image` that's a relative reference (common in the wild despite the OG spec requiring absolute URLs) against the page it came from. The image is only fetched and rehosted when `server_name` is given. Public for direct unit testing of the parsing logic, independent of the SSRF-gated fetch."
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

    with image_url when is_binary(image_url) and is_binary(server_name) <-
           find_meta(html, "og:image"),
         resolved = if(page_url, do: resolve_url(page_url, image_url), else: image_url),
         {:ok, image} <- fetch_image(resolved, server_name) do
      Map.merge(base, image)
    else
      _ -> base
    end
  end

  defp maybe_put_meta(acc, html, og_key, out_key) do
    maybe_put(acc, "og:#{out_key}", find_meta(html, og_key))
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
    dimensions = get_image_dimensions(body, content_type) || %{}

    case Store.upload("url_preview", content_type, body, server_name) do
      {:ok, media_id} ->
        %{
          "og:image" => "mxc://#{server_name}/#{media_id}",
          "matrix:image:size" => byte_size(body)
        }
        |> maybe_put("og:image:width", dimensions[:width])
        |> maybe_put("og:image:height", dimensions[:height])

      {:error, _} ->
        %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Image dimensions
  # ---------------------------------------------------------------------------

  @jpeg_sof_markers [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]

  @doc "Parses width/height out of raw image bytes, by `content_type`. Returns `%{width:, height:}`, or `nil` for an unsupported type or malformed/truncated data. Public for direct unit testing against real fixture bytes, independent of the SSRF-gated fetch."
  def get_image_dimensions(body, content_type) when is_binary(body) do
    case dimensions(base_content_type(content_type), body) do
      {width, height} -> %{width: width, height: height}
      nil -> nil
    end
  end

  defp dimensions(
         "image/png",
         <<0x89, "PNG\r\n", 0x1A, "\n", _len::32, "IHDR", w::32, h::32, _::binary>>
       ),
       do: {w, h}

  defp dimensions("image/gif", <<"GIF8", v, "a", w::16-little, h::16-little, _::binary>>)
       when v in [?7, ?9],
       do: {w, h}

  defp dimensions(type, <<0xFF, 0xD8, rest::binary>>) when type in ["image/jpeg", "image/jpg"],
    do: jpeg_dimensions(rest)

  defp dimensions(
         "image/webp",
         <<"RIFF", _::32, "WEBP", chunk::binary-size(4), _::32, data::binary>>
       ),
       do: webp_dimensions(chunk, data)

  defp dimensions(_type, _body), do: nil

  # Fill bytes before a marker.
  defp jpeg_dimensions(<<0xFF, 0xFF, rest::binary>>), do: jpeg_dimensions(<<0xFF, rest::binary>>)

  defp jpeg_dimensions(<<0xFF, marker, _len::16, _precision, h::16, w::16, _::binary>>)
       when marker in @jpeg_sof_markers,
       do: {w, h}

  # Standalone markers (TEM, RSTn) carry no length field.
  defp jpeg_dimensions(<<0xFF, marker, rest::binary>>)
       when marker == 0x01 or marker in 0xD0..0xD7,
       do: jpeg_dimensions(rest)

  defp jpeg_dimensions(<<0xFF, marker, len::16, rest::binary>>)
       when marker not in [0xD9, 0xDA] and len >= 2 and byte_size(rest) >= len - 2,
       do: jpeg_dimensions(binary_part(rest, len - 2, byte_size(rest) - (len - 2)))

  defp jpeg_dimensions(_), do: nil

  defp webp_dimensions(
         "VP8 ",
         <<_frame_tag::24, 0x9D, 0x01, 0x2A, w::16-little, h::16-little, _::binary>>
       ),
       do: {w &&& 0x3FFF, h &&& 0x3FFF}

  defp webp_dimensions("VP8L", <<0x2F, bits::32-little, _::binary>>),
    do: {(bits &&& 0x3FFF) + 1, (bits >>> 14 &&& 0x3FFF) + 1}

  defp webp_dimensions("VP8X", <<_flags::32, w::24-little, h::24-little, _::binary>>),
    do: {w + 1, h + 1}

  defp webp_dimensions(_chunk, _data), do: nil

  # ---------------------------------------------------------------------------
  # SSRF validation
  # ---------------------------------------------------------------------------

  # Returns {:ok, address} — the single literal address the actual
  # connection must be pinned to (see moduledoc "DNS rebinding").
  # NetworkAddress.check/1 rejects the host if *any* resolved address is
  # private, not only the one we'd pin to.
  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        with {:ok, [address | _]} <- check_host(host), do: {:ok, address}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp check_host(host) do
    if private_addresses_blocked?(),
      do: NetworkAddress.check(host),
      else: NetworkAddress.resolve(host)
  end

  # Off only for the Complement test harness (complement/start.sh sets
  # URL_PREVIEW_ALLOW_PRIVATE_ADDRESSES, consumed in config/runtime.exs) —
  # Complement's own test webserver is only reachable via the Docker host
  # gateway, which is itself a private address.
  defp private_addresses_blocked? do
    not Application.get_env(:axon_media, :url_preview_allow_private_addresses, false)
  end

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
        socket = Mint.HTTP.get_socket(conn)

        # Only this connection's socket messages — anything else in the
        # caller's mailbox is left alone.
        receive do
          {tag, ^socket, _} = message when tag in [:tcp, :ssl, :tcp_error, :ssl_error] ->
            stream_message(conn, ref, acc, deadline_ms, message)

          {tag, ^socket} = message when tag in [:tcp_closed, :ssl_closed] ->
            stream_message(conn, ref, acc, deadline_ms, message)
        after
          timeout -> {:error, :timeout}
        end
    end
  end

  defp stream_message(conn, ref, acc, deadline_ms, message) do
    case Mint.HTTP.stream(conn, message) do
      {:ok, conn, responses} ->
        acc = Enum.reduce(responses, acc, &apply_response(&1, &2, ref))
        receive_response(conn, ref, acc, deadline_ms)

      {:error, _conn, reason, _responses} ->
        {:error, reason}

      :unknown ->
        receive_response(conn, ref, acc, deadline_ms)
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
