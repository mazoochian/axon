defmodule AxonWeb.MediaControllerTest do
  @moduledoc """
  Covers the gaps `phase4_test.exs` doesn't: `url_preview` and
  download-of-unknown-media. Upload/download/thumbnail happy paths are
  already covered there. See `AxonMedia.UrlPreviewTest` for the SSRF
  blocking / OpenGraph parsing unit coverage this end-to-end layer builds on.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers
  alias AxonCore.Repo
  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}

  test "url_preview requires a url param" do
    alice = register("mediaprev_missing_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/media/preview_url")
    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_MISSING_PARAM"
  end

  test "url_preview rejects a private/loopback target instead of fetching it" do
    alice = register("mediaprev_blocked_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> get(
        "/_matrix/client/v3/media/preview_url?url=" <>
          URI.encode_www_form("http://127.0.0.1/secret")
      )

    assert conn.status == 400
  end

  test "url_preview serves a cached result on both the v1 and v3 paths" do
    alice = register("mediaprev_cached_#{System.unique_integer([:positive])}")
    url = "http://127.0.0.1/would-normally-be-blocked-#{System.unique_integer([:positive])}"
    data = %{"og:title" => "A Cached Page"}

    Repo.insert_all("url_previews", [
      %{url: url, data: data, fetched_at: DateTime.utc_now(:microsecond)}
    ])

    encoded = URI.encode_www_form(url)

    v3_conn = authed(alice.token) |> get("/_matrix/client/v3/media/preview_url?url=#{encoded}")
    assert v3_conn.status == 200
    assert decode(v3_conn) == data

    v1_conn = authed(alice.token) |> get("/_matrix/client/v1/media/preview_url?url=#{encoded}")
    assert v1_conn.status == 200
    assert decode(v1_conn) == data
  end

  test "downloading an unknown local media_id 404s" do
    conn = build_conn() |> get("/_matrix/media/v3/download/localhost/nonexistent_media_id")
    assert conn.status == 404
  end

  test "thumbnailing an unknown local media_id 404s" do
    conn =
      build_conn()
      |> get("/_matrix/media/v3/thumbnail/localhost/nonexistent_media_id?width=32&height=32")

    assert conn.status == 404
  end

  test "uploading an empty body is rejected with M_MISSING_PARAM" do
    alice = register("mediaupload_empty_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> put_req_header("content-type", "text/plain")
      |> post("/_matrix/client/v3/media/upload", "")

    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_MISSING_PARAM"
  end

  test "a thumbnail generation failure (not merely unsupported type) is reported as 500" do
    alice = register("mediathumb_fail_#{System.unique_integer([:positive])}")

    upload_conn =
      authed(alice.token)
      |> put_req_header("content-type", "image/png")
      |> post("/_matrix/client/v3/media/upload", "this is not actually a valid png file")

    assert upload_conn.status == 200
    media_id = decode(upload_conn)["content_uri"] |> String.split("/") |> List.last()

    conn =
      build_conn()
      |> get("/_matrix/media/v3/thumbnail/localhost/#{media_id}?width=32&height=32")

    assert conn.status == 500
    assert decode(conn)["errcode"] == "M_UNKNOWN"
  end

  test "downloading media from an unreachable remote server 502s instead of crashing" do
    conn =
      build_conn()
      |> get("/_matrix/media/v3/download/127.0.0.1:1/some_media_id")

    assert conn.status == 502
    assert decode(conn)["errcode"] == "M_UNKNOWN"
  end

  test "thumbnailing media from an unreachable remote server 502s instead of crashing" do
    conn =
      build_conn()
      |> get("/_matrix/media/v3/thumbnail/127.0.0.1:1/some_media_id?width=32&height=32")

    assert conn.status == 502
    assert decode(conn)["errcode"] == "M_UNKNOWN"
  end

  # ---------------------------------------------------------------------------
  # Federation media (MSC3916 / Matrix 1.11): authenticated, multipart/mixed
  # ---------------------------------------------------------------------------

  describe "federation media endpoints" do
    setup do
      port = 18_600
      server_name = "fake-inmedia-#{System.unique_integer([:positive])}.test"

      start_supervised!({FakeRemoteMatrixServer, port: port, server_name: server_name})
      KeyCache.clear()

      Application.put_env(:axon_federation, :server_overrides, %{
        server_name => "http://127.0.0.1:#{port}"
      })

      on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)

      %{port: port, server_name: server_name}
    end

    defp boundary_of(content_type) do
      [_, boundary] = Regex.run(~r/boundary="?([^";]+)"?/, content_type)
      boundary
    end

    defp multipart_parts(content_type, body) do
      boundary = boundary_of(content_type)

      body
      |> String.split("--" <> boundary)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 in ["", "--"]))
      |> Enum.map(fn raw ->
        [headers, content] = String.split(raw, ~r/\r?\n\r?\n/, parts: 2)
        {headers, content}
      end)
    end

    test "GET federation/v1/media/download serves local media as multipart/mixed", %{
      port: port
    } do
      alice = register("fedmedia_dl_#{System.unique_integer([:positive])}")

      upload_conn =
        authed(alice.token)
        |> put_req_header("content-type", "text/plain")
        |> post("/_matrix/client/v3/media/upload", "hello federation media")

      assert upload_conn.status == 200
      media_id = decode(upload_conn)["content_uri"] |> String.split("/") |> List.last()

      header =
        FakeRemoteMatrixServer.sign_request(
          port,
          "GET",
          "/_matrix/federation/v1/media/download/#{media_id}"
        )

      conn =
        build_conn()
        |> put_req_header("authorization", header)
        |> get("/_matrix/federation/v1/media/download/#{media_id}")

      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "multipart/mixed"

      [{json_headers, json_body}, {file_headers, file_body}] =
        multipart_parts(content_type, conn.resp_body)

      assert json_headers =~ "application/json"
      assert Jason.decode!(json_body) == %{}
      assert file_headers =~ "text/plain"
      assert file_body == "hello federation media"
    end

    test "GET federation/v1/media/download 404s for unknown media", %{port: port} do
      header =
        FakeRemoteMatrixServer.sign_request(
          port,
          "GET",
          "/_matrix/federation/v1/media/download/nonexistent"
        )

      conn =
        build_conn()
        |> put_req_header("authorization", header)
        |> get("/_matrix/federation/v1/media/download/nonexistent")

      assert conn.status == 404
      assert decode(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "outbound: downloading non-local media fetches it via the authenticated federation endpoint" do
      port = 18_601
      server_name = "fake-inmedia-#{System.unique_integer([:positive])}.test"

      start_supervised!({FakeRemoteMatrixServer, port: port, server_name: server_name})
      KeyCache.clear()

      Application.put_env(:axon_federation, :server_overrides, %{
        server_name => "http://127.0.0.1:#{port}"
      })

      on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)

      boundary = "testboundary"

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
          "Content-Type: image/png\r\n\r\n",
          "remote-png-bytes",
          "\r\n",
          "--",
          boundary,
          "--\r\n"
        ])

      FakeRemoteMatrixServer.put_raw_response(
        port,
        {"GET", ~r{^/_matrix/federation/v1/media/download/}},
        200,
        "multipart/mixed; boundary=#{boundary}",
        body
      )

      conn = build_conn() |> get("/_matrix/media/v3/download/#{server_name}/some-media-id")

      assert conn.status == 200
      assert conn.resp_body == "remote-png-bytes"
      # put_resp_content_type/2 (used consistently for every download path
      # in this controller, local or proxied) appends "; charset=utf-8" per
      # Plug's MIME database defaults — not specific to this new path.
      assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
    end
  end
end
