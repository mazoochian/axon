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
