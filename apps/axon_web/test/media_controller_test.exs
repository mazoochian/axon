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
end
