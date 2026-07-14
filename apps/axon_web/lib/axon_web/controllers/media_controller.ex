defmodule AxonWeb.MediaController do
  use Phoenix.Controller, formats: [:json]

  require Logger

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

    filename = params["filename"]
    _ = filename

    case Plug.Conn.read_body(conn, length: 100_000_000) do
      {:ok, body, _conn} when byte_size(body) > 0 ->
        case Store.upload(user_id, content_type, body, server_name) do
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
  def download(conn, %{"server_name" => origin_server, "media_id" => media_id} = _params) do
    local_server = Application.fetch_env!(:axon_web, :server_name)

    if origin_server == local_server do
      serve_local(conn, media_id)
    else
      proxy_remote(conn, origin_server, media_id)
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

  defp serve_local(conn, media_id) do
    case Store.download(media_id) do
      {:ok, {content_type, data}} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("content-disposition", "inline")
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
            |> put_resp_content_type(ct)
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

  defp proxy_remote(conn, origin_server, media_id) do
    url = "https://#{origin_server}/_matrix/media/v3/download/#{origin_server}/#{media_id}"
    proxy_get(conn, url)
  end

  defp proxy_remote_thumbnail(conn, origin_server, media_id, params) do
    query = URI.encode_query(Map.take(params, ["width", "height", "method", "animated"]))

    url =
      "https://#{origin_server}/_matrix/media/v3/thumbnail/#{origin_server}/#{media_id}?#{query}"

    proxy_get(conn, url)
  end

  defp proxy_get(conn, url) do
    req = Finch.build(:get, url)

    case Finch.request(req, Axon.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: body, headers: headers}} ->
        content_type =
          headers
          |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
          |> case do
            {_, v} -> v
            nil -> "application/octet-stream"
          end

        conn
        |> put_resp_content_type(content_type)
        |> send_resp(200, body)

      {:ok, %Finch.Response{status: status}} when status in [404, 403] ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Remote media not found"})

      {:error, reason} ->
        Logger.warning("Remote media fetch failed for #{url}: #{inspect(reason)}")

        conn
        |> put_status(502)
        |> json(%{"errcode" => "M_UNKNOWN", "error" => "Failed to fetch remote media"})
    end
  end
end
