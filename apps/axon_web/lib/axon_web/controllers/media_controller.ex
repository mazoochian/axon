defmodule AxonWeb.MediaController do
  use Phoenix.Controller, formats: [:json]

  require Logger

  plug(AxonWeb.Plug.RateLimit, [bucket: :media_upload, key_by: :user] when action == :upload)

  plug(
    AxonWeb.Plug.RateLimit,
    [bucket: :url_preview, key_by: :user] when action == :url_preview
  )

  alias AxonMedia.{Store, Thumbnailer}

  # POST /_matrix/media/v3/upload  (also /_matrix/client/v3/media/upload)
  def upload(conn, params) do
    user_id = conn.assigns[:current_user_id]
    server_name = Application.fetch_env!(:axon_web, :server_name)

    content_type =
      case Plug.Conn.get_req_header(conn, "content-type") do
        [ct | _] -> ct
        [] -> "application/octet-stream"
      end

    # Strip any charset suffix (e.g. "image/png; charset=utf-8")
    content_type = content_type |> String.split(";") |> hd() |> String.trim()

    # ?filename= is a query param per spec, not a body field — persisted so
    # a later download can return it via Content-Disposition (spec: "If the
    # upload was made with a filename, this header MUST contain the same
    # filename"). Previously read into a local and immediately discarded.
    filename = non_empty(params["filename"])

    case Plug.Conn.read_body(conn, length: 100_000_000) do
      {:ok, body, _conn} when byte_size(body) > 0 ->
        case Store.upload(user_id, content_type, body, server_name, filename) do
          {:ok, media_id} ->
            mxc_uri = "mxc://#{server_name}/#{media_id}"
            json(conn, %{"content_uri" => mxc_uri})

          {:error, reason} ->
            Logger.error("Media upload failed: #{inspect(reason)}")

            conn
            |> put_status(500)
            |> json(%{"errcode" => "M_UNKNOWN", "error" => "Upload failed"})
        end

      {:ok, <<>>, _conn} ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "Empty body"})

      {:error, :too_large} ->
        conn
        |> put_status(413)
        |> json(%{"errcode" => "M_TOO_LARGE", "error" => "Upload too large"})

      {:error, reason} ->
        Logger.error("Body read error: #{inspect(reason)}")

        conn
        |> put_status(500)
        |> json(%{"errcode" => "M_UNKNOWN", "error" => "Failed to read body"})
    end
  end

  # GET /_matrix/media/v3/download/:server_name/:media_id
  # GET /_matrix/media/v3/download/:server_name/:media_id/:filename
  def download(conn, %{"server_name" => origin_server, "media_id" => media_id} = params) do
    local_server = Application.fetch_env!(:axon_web, :server_name)
    override_filename = non_empty(params["filename"])

    if origin_server == local_server do
      serve_local(conn, media_id, override_filename)
    else
      proxy_remote(conn, origin_server, media_id, override_filename)
    end
  end

  # GET /_matrix/media/v3/thumbnail/:server_name/:media_id?width=&height=&method=
  def thumbnail(conn, %{"server_name" => origin_server, "media_id" => media_id} = params) do
    if origin_server == Application.fetch_env!(:axon_web, :server_name) do
      serve_local_thumbnail(conn, media_id, params)
    else
      proxy_remote_thumbnail(conn, origin_server, media_id, params)
    end
  end

  # GET /_matrix/client/v1/media/preview_url (also /v3, kept for older clients)
  def url_preview(conn, %{"url" => url}) do
    server_name = Application.fetch_env!(:axon_web, :server_name)

    case AxonMedia.UrlPreview.fetch(url, server_name) do
      {:ok, data} ->
        json(conn, data)

      {:error, reason} when reason in [:invalid_url, :blocked_address] ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_UNKNOWN", "error" => "URL cannot be previewed"})

      {:error, _reason} ->
        conn
        |> put_status(502)
        |> json(%{"errcode" => "M_UNKNOWN", "error" => "Failed to fetch URL preview"})
    end
  end

  def url_preview(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "url is required"})
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Every `put_resp_content_type/2` call below is deliberately 2-arity with
  # an explicit `nil` charset, not the 1-arity default: `Plug.Conn`'s
  # default charset is `"utf-8"`, which it appends unconditionally
  # (`"image/png; charset=utf-8"`) regardless of whether the media type is
  # even text. Per spec the response's Content-Type must echo back exactly
  # what was supplied at upload (`POST .../media/v3/upload`'s
  # `Content-Type` header, stored byte-for-byte, arbitrary and opaque —
  # not necessarily even a real IANA type) — silently mutating it broke
  # every client comparing the two verbatim.
  defp serve_local(conn, media_id, override_filename \\ nil) do
    case Store.download(media_id) do
      {:ok, %{content_type: content_type, data: data, filename: stored_filename}} ->
        conn
        |> put_resp_content_type(content_type, nil)
        |> put_resp_header(
          "content-disposition",
          content_disposition(content_type, override_filename || stored_filename)
        )
        |> send_resp(200, data)

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Media not found"})
    end
  end

  defp serve_local_thumbnail(conn, media_id, params) do
    case Store.get_meta(media_id) do
      %{content_type: content_type, storage_path: path} when is_binary(path) ->
        case Thumbnailer.generate(
               media_id,
               path,
               content_type,
               params["width"],
               params["height"],
               params["method"]
             ) do
          {:ok, {ct, data}} ->
            conn
            |> put_resp_content_type(ct, nil)
            |> put_resp_header("content-disposition", "inline")
            |> send_resp(200, data)

          {:error, :unsupported_content_type} ->
            # Not a thumbnailable image (e.g. a PDF) — fall back to the original.
            serve_local(conn, media_id)

          {:error, reason} ->
            Logger.error("Thumbnail generation failed for #{media_id}: #{inspect(reason)}")

            conn
            |> put_status(500)
            |> json(%{"errcode" => "M_UNKNOWN", "error" => "Thumbnail generation failed"})
        end

      _ ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Media not found"})
    end
  end

  # Tries the authenticated MSC3916/Matrix-1.11 federation media endpoint
  # first (AxonFederation.MediaFetch falls back to the deprecated
  # unauthenticated one itself on an explicit M_UNRECOGNIZED 404) — this
  # replaces a previous implementation that always spoke the deprecated
  # endpoint directly to a hardcoded `https://origin_server/` (bypassing
  # federation TLS port resolution and X-Matrix signing entirely, so it
  # only ever worked against a server reachable on port 443 with no auth
  # required — never true for another axon/Complement instance, and
  # increasingly not true for any spec-compliant server as the deprecated
  # endpoint is phased out).
  defp proxy_remote(conn, origin_server, media_id, override_filename) do
    case AxonFederation.MediaFetch.download(origin_server, media_id) do
      {:ok, content_type, data, remote_filename} ->
        conn
        |> put_resp_content_type(content_type, nil)
        |> put_resp_header(
          "content-disposition",
          content_disposition(content_type, override_filename || remote_filename)
        )
        |> send_resp(200, data)

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Remote media not found"})

      {:error, reason} ->
        Logger.warning(
          "Remote media fetch failed for #{origin_server}/#{media_id}: #{inspect(reason)}"
        )

        conn
        |> put_status(502)
        |> json(%{"errcode" => "M_UNKNOWN", "error" => "Failed to fetch remote media"})
    end
  end

  defp proxy_remote_thumbnail(conn, origin_server, media_id, params) do
    query = Map.take(params, ["width", "height", "method", "animated"])

    case AxonFederation.MediaFetch.thumbnail(origin_server, media_id, query) do
      {:ok, content_type, data, _filename} ->
        conn
        |> put_resp_content_type(content_type, nil)
        |> send_resp(200, data)

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Remote media not found"})

      {:error, reason} ->
        Logger.warning(
          "Remote thumbnail fetch failed for #{origin_server}/#{media_id}: #{inspect(reason)}"
        )

        conn
        |> put_status(502)
        |> json(%{"errcode" => "M_UNKNOWN", "error" => "Failed to fetch remote media"})
    end
  end

  # ---------------------------------------------------------------------------
  # Federation-facing (MSC3916/Matrix 1.11): GET /_matrix/federation/v1/media/{download,thumbnail}
  # The 200 response is multipart/mixed: an application/json metadata part
  # (always {} — axon has no per-media metadata beyond content-type today)
  # followed by the media bytes.
  # ---------------------------------------------------------------------------

  def federation_download(conn, %{"media_id" => media_id}) do
    case Store.download(media_id) do
      {:ok, %{content_type: content_type, data: data, filename: filename}} ->
        send_multipart_media(conn, content_type, data, filename)

      {:error, :not_found} ->
        media_not_found(conn)
    end
  end

  def federation_thumbnail(conn, %{"media_id" => media_id} = params) do
    case Store.get_meta(media_id) do
      %{content_type: content_type, storage_path: path} when is_binary(path) ->
        case Thumbnailer.generate(
               media_id,
               path,
               content_type,
               params["width"],
               params["height"],
               params["method"]
             ) do
          {:ok, {ct, data}} ->
            send_multipart_media(conn, ct, data, nil)

          {:error, :unsupported_content_type} ->
            case Store.download(media_id) do
              {:ok, %{content_type: ct, data: data, filename: filename}} ->
                send_multipart_media(conn, ct, data, filename)

              {:error, :not_found} ->
                media_not_found(conn)
            end

          {:error, reason} ->
            Logger.error(
              "Federation thumbnail generation failed for #{media_id}: #{inspect(reason)}"
            )

            conn
            |> put_status(502)
            |> json(%{"errcode" => "M_UNKNOWN", "error" => "Thumbnail generation failed"})
        end

      _ ->
        media_not_found(conn)
    end
  end

  defp media_not_found(conn) do
    conn
    |> put_status(404)
    |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Media not found"})
  end

  defp send_multipart_media(conn, content_type, data, filename) do
    boundary = "axonmedia" <> (16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))

    body =
      IO.iodata_to_binary([
        "--",
        boundary,
        "\r\n",
        "Content-Type: application/json\r\n\r\n",
        "{}",
        "\r\n",
        "--",
        boundary,
        "\r\n",
        "Content-Type: ",
        content_type,
        "\r\n",
        "Content-Disposition: ",
        content_disposition(content_type, filename),
        "\r\n\r\n",
        data,
        "\r\n",
        "--",
        boundary,
        "--\r\n"
      ])

    conn
    |> put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
    |> send_resp(200, body)
  end

  # ---------------------------------------------------------------------------
  # Content-Disposition (spec: "Serving inline content" + media download's
  # 200-response headers)
  # ---------------------------------------------------------------------------

  # Content-Types the spec allows serving as `inline` without inviting XSS
  # from a maliciously-uploaded HTML/SVG/etc. file being rendered as such —
  # everything else gets `attachment` regardless of what the uploader
  # claimed its type was.
  @inline_safe_content_types ~w(
    text/css text/plain text/csv application/json application/ld+json
    image/jpeg image/gif image/png image/apng image/webp image/avif
    video/mp4 video/webm video/ogg video/quicktime
    audio/mp4 audio/webm audio/aac audio/mpeg audio/ogg
    audio/wave audio/wav audio/x-wav audio/x-pn-wav audio/flac audio/x-flac
  )

  defp content_disposition(content_type, filename) do
    disposition = if inline_safe?(content_type), do: "inline", else: "attachment"

    case non_empty(filename) do
      nil -> disposition
      name -> "#{disposition}; #{filename_param(name)}"
    end
  end

  defp inline_safe?(content_type) do
    base_type =
      content_type
      |> to_string()
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

    base_type in @inline_safe_content_types
  end

  # Plain quoted-string for an ASCII-safe name (handles embedded spaces/
  # semicolons/etc. fine once quoted — just needs its own quotes/backslashes
  # escaped); RFC 6266's filename*=UTF-8''<pct-encoded> extended form
  # otherwise, since a raw non-ASCII byte isn't valid inside an HTTP header
  # quoted-string.
  defp filename_param(name) do
    if ascii_only?(name) and not String.contains?(name, ["\r", "\n"]) do
      ~s(filename="#{escape_quoted(name)}")
    else
      ~s(filename*=UTF-8''#{URI.encode(name, &URI.char_unreserved?/1)})
    end
  end

  defp ascii_only?(name), do: name |> String.to_charlist() |> Enum.all?(&(&1 < 128))

  defp escape_quoted(name),
    do: name |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(str), do: str
end
