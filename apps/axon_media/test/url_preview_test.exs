defmodule AxonMedia.UrlPreviewTest do
  @moduledoc """
  Regression tests for Phase 14's SSRF-hardened URL preview fetching.

  Two things need testing very differently:

    - SSRF blocking: real network calls, asserted to be *rejected* before
      any connection is attempted (private/loopback/link-local/reserved
      addresses, non-http(s) schemes) — no fake server needed, since the
      whole point is these never get dialed.
    - OpenGraph parsing: exercised directly against `extract_og/2` with
      canned HTML, independent of the network layer entirely — faking a
      real "successful fetch of a public URL" would mean either hitting
      the real internet from tests (bad practice) or weakening the SSRF
      gate just for testing (defeats the point of testing it). The cache
      test below covers the "successful preview returned end-to-end"
      shape without either problem, since a cache hit is intentionally
      checked *before* SSRF validation.
  """

  use AxonMedia.DataCase, async: false

  alias AxonCore.Repo
  alias AxonMedia.UrlPreview

  describe "extract_og/2 (OpenGraph parsing)" do
    test "reads og:title/description/site_name from meta tags" do
      html = """
      <html><head>
        <meta property="og:title" content="Example Title">
        <meta property="og:description" content="Example description here">
        <meta property="og:site_name" content="Example Site">
      </head></html>
      """

      assert UrlPreview.extract_og(html) == %{
               "og:title" => "Example Title",
               "og:description" => "Example description here",
               "og:site_name" => "Example Site"
             }
    end

    test "reads og:type and og:url from meta tags (Complement TestUrlPreview compatibility)" do
      html = ~s"""
      <html prefix="og: http://ogp.me/ns#">
      <head>
      <title>The Rock (1996)</title>
      <meta property="og:title" content="The Rock" />
      <meta property="og:type" content="video.movie" />
      <meta property="og:url" content="http://www.imdb.com/title/tt0117500/" />
      <meta property="og:image" content="http://example.com/test.png" />
      </head>
      <body></body>
      </html>
      """

      # Pre-populate cache with image data to avoid actual HTTP fetch
      image_url = "http://example.com/test.png"
      # This is the actual matrix.png from Complement (2239 bytes, 279x129)
      png_data = Base.decode64!("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")
      Repo.insert_all("url_previews", [
        %{url: image_url, data: %{"__image__" => %{"og:image" => "mxc://example.com/abc123", "matrix:image:size" => byte_size(png_data), "og:image:width" => 279, "og:image:height" => 129}}, fetched_at: DateTime.utc_now(:microsecond)}
      ])

      result = UrlPreview.extract_og(html, "example.com")
      assert result["og:title"] == "The Rock"
      assert result["og:type"] == "video.movie"
      assert result["og:url"] == "http://www.imdb.com/title/tt0117500/"
      assert result["og:image"] =~ ~r/^mxc:\/\/example\.com\//
      assert result["matrix:image:size"] == 2239
      assert result["og:image:width"] == 279
      assert result["og:image:height"] == 129
    end

    test "resolves a relative og:image against the page's own URL (Complement TestUrlPreview uses one)" do
      html = ~s"""
      <html><head>
      <meta property="og:title" content="The Rock" />
      <meta property="og:image" content="test.png" />
      </head></html>
      """

      # Same fixture as the absolute-URL test above, keyed by what "test.png"
      # must resolve to once merged against the page URL.
      resolved_image_url = "http://example.com/path/test.png"
      png_data = Base.decode64!("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")
      Repo.insert_all("url_previews", [
        %{url: resolved_image_url, data: %{"__image__" => %{"og:image" => "mxc://example.com/abc123", "matrix:image:size" => byte_size(png_data), "og:image:width" => 279, "og:image:height" => 129}}, fetched_at: DateTime.utc_now(:microsecond)}
      ])

      result = UrlPreview.extract_og(html, "example.com", "http://example.com/path/page.html")
      assert result["og:title"] == "The Rock"
      assert result["og:image"] =~ ~r/^mxc:\/\/example\.com\//
      assert result["matrix:image:size"] == 2239
    end

    test "falls back to <title> when og:title is absent" do
      html = "<html><head><title> Plain Title </title></head></html>"
      assert UrlPreview.extract_og(html)["og:title"] == "Plain Title"
    end

    test "unescapes HTML entities in meta content" do
      html = ~s|<meta property="og:title" content="Fish &amp; Chips">|
      assert UrlPreview.extract_og(html)["og:title"] == "Fish & Chips"
    end

    test "returns an empty map for HTML with no relevant tags" do
      assert UrlPreview.extract_og("<html><body>hi</body></html>") == %{}
    end
  end

  describe "get_image_dimensions/2" do
    test "parses real PNG width/height from the IHDR chunk" do
      # Same matrix.png fixture as the extract_og tests above (2239 bytes, 279x129).
      png_data = Base.decode64!("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")

      assert UrlPreview.get_image_dimensions(png_data, "image/png") == %{width: 279, height: 129}
    end
  end

  describe "SSRF blocking" do
    test "rejects a non-http(s) scheme" do
      assert {:error, :invalid_url} = UrlPreview.fetch("ftp://example.com/file", "localhost")
    end

    test "rejects a URL with no host" do
      assert {:error, :invalid_url} = UrlPreview.fetch("not a url", "localhost")
    end

    test "rejects literal loopback, private, link-local, and CGNAT IPv4 addresses" do
      for host <- [
            "127.0.0.1",
            "10.0.0.1",
            "192.168.1.1",
            "172.16.0.5",
            "169.254.169.254",
            "100.64.0.1"
          ] do
        assert {:error, :blocked_address} = UrlPreview.fetch("http://#{host}/", "localhost"),
               "expected #{host} to be blocked"
      end
    end

    test "rejects literal IPv6 loopback and link-local addresses" do
      for host <- ["[::1]", "[fe80::1]"] do
        assert {:error, :blocked_address} = UrlPreview.fetch("http://#{host}/", "localhost"),
               "expected #{host} to be blocked"
      end
    end

    test "rejects a hostname that resolves to localhost" do
      assert {:error, :blocked_address} = UrlPreview.fetch("http://localhost/", "localhost")
    end

    test "rejects the 0.0.0.0/8 range" do
      assert {:error, :blocked_address} = UrlPreview.fetch("http://0.0.0.1/", "localhost")
    end

    test "rejects IPv4 multicast/reserved addresses (>= 224.0.0.0)" do
      for host <- ["224.0.0.1", "240.0.0.1", "255.255.255.255"] do
        assert {:error, :blocked_address} = UrlPreview.fetch("http://#{host}/", "localhost"),
               "expected #{host} to be blocked"
      end
    end

    test "rejects the IPv6 unspecified address ::" do
      assert {:error, :blocked_address} = UrlPreview.fetch("http://[::]/", "localhost")
    end

    test "rejects IPv6 unique-local addresses (fc00::/7)" do
      for host <- ["[fc00::1]", "[fd12:3456:789a::1]"] do
        assert {:error, :blocked_address} = UrlPreview.fetch("http://#{host}/", "localhost"),
               "expected #{host} to be blocked"
      end
    end

    test "rejects IPv4-mapped IPv6 addresses whose unwrapped IPv4 is private" do
      assert {:error, :blocked_address} =
               UrlPreview.fetch("http://[::ffff:127.0.0.1]/", "localhost")
    end
  end

  describe "cache" do
    test "a cache hit is returned without re-validating or re-fetching, even for an otherwise-blocked url" do
      url = "http://127.0.0.1/would-normally-be-blocked-#{System.unique_integer([:positive])}"
      data = %{"og:title" => "Cached Title"}

      Repo.insert_all("url_previews", [
        %{url: url, data: data, fetched_at: DateTime.utc_now(:microsecond)}
      ])

      assert UrlPreview.fetch(url, "localhost") == {:ok, data}
    end

    test "an expired cache entry is not returned" do
      url = "http://127.0.0.1/expired-#{System.unique_integer([:positive])}"
      stale = DateTime.add(DateTime.utc_now(), -7200, :second)

      Repo.insert_all("url_previews", [
        %{url: url, data: %{"og:title" => "Stale"}, fetched_at: stale}
      ])

      # Falls through to real validation, which rejects the loopback host.
      assert {:error, :blocked_address} = UrlPreview.fetch(url, "localhost")
    end
  end
end
