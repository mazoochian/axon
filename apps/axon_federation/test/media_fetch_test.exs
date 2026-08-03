defmodule AxonFederation.MediaFetchTest do
  @moduledoc """
  `AxonFederation.MediaFetch` — the client side of MSC3916/Matrix 1.11
  authenticated federation media (`/_matrix/federation/v1/media/{download,thumbnail}`,
  multipart/mixed responses), including the fallback to the deprecated
  unauthenticated endpoint on an explicit `M_UNRECOGNIZED` 404.
  """

  use ExUnit.Case, async: false

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache, MediaFetch}

  setup do
    port = 18_500 + System.unique_integer([:positive, :monotonic])
    server_name = "fake-media-#{System.unique_integer([:positive])}.test"

    start_supervised!({FakeRemoteMatrixServer, port: port, server_name: server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      server_name => "http://127.0.0.1:#{port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)

    %{port: port, server_name: server_name}
  end

  defp multipart_body(boundary, content_type, data, extra_headers \\ "") do
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
      extra_headers,
      "\r\n",
      data,
      "\r\n",
      "--",
      boundary,
      "--\r\n"
    ])
  end

  test "download/2 parses a real multipart/mixed federation media response", %{
    port: port,
    server_name: server_name
  } do
    body = multipart_body("abc123", "image/png", "fake-png-bytes")

    FakeRemoteMatrixServer.put_raw_response(
      port,
      {"GET", ~r{^/_matrix/federation/v1/media/download/}},
      200,
      "multipart/mixed; boundary=abc123",
      body
    )

    assert {:ok, "image/png", "fake-png-bytes"} =
             MediaFetch.download(server_name, "some-media-id")
  end

  test "download/2 falls back to the legacy endpoint on M_UNRECOGNIZED", %{
    port: port,
    server_name: server_name
  } do
    FakeRemoteMatrixServer.put_response(
      port,
      {"GET", ~r{^/_matrix/federation/v1/media/download/}},
      404,
      %{"errcode" => "M_UNRECOGNIZED", "error" => "Unrecognized request"}
    )

    FakeRemoteMatrixServer.put_raw_response(
      port,
      {"GET", ~r{^/_matrix/media/v3/download/}},
      200,
      "text/plain",
      "legacy-bytes"
    )

    assert {:ok, "text/plain", "legacy-bytes"} =
             MediaFetch.download(server_name, "some-media-id")

    [req] =
      FakeRemoteMatrixServer.requests(port)
      |> Enum.filter(&(&1.path =~ "/_matrix/media/v3/download/"))

    assert req.query_string =~ "allow_remote=false"
  end

  test "download/2 reports a genuine not-found without falling back", %{
    port: port,
    server_name: server_name
  } do
    FakeRemoteMatrixServer.put_response(
      port,
      {"GET", ~r{^/_matrix/federation/v1/media/download/}},
      404,
      %{"errcode" => "M_NOT_FOUND", "error" => "Not found"}
    )

    assert {:error, :not_found} = MediaFetch.download(server_name, "missing-media-id")

    refute Enum.any?(
             FakeRemoteMatrixServer.requests(port),
             &(&1.path =~ "/_matrix/media/v3/download/")
           )
  end

  test "download/2 follows a Location redirect in the file part", %{
    port: port,
    server_name: server_name
  } do
    redirect_port = port + 1

    Bandit.start_link(
      plug: {AxonFederation.MediaFetchTest.RedirectTarget, []},
      ip: {127, 0, 0, 1},
      port: redirect_port
    )
    |> case do
      {:ok, pid} -> on_exit(fn -> Process.exit(pid, :kill) end)
      _ -> :ok
    end

    body =
      multipart_body(
        "xyz",
        "image/jpeg",
        "",
        "Location: http://127.0.0.1:#{redirect_port}/somewhere\r\n"
      )

    FakeRemoteMatrixServer.put_raw_response(
      port,
      {"GET", ~r{^/_matrix/federation/v1/media/download/}},
      200,
      "multipart/mixed; boundary=xyz",
      body
    )

    assert {:ok, "image/jpeg", "redirected-bytes"} =
             MediaFetch.download(server_name, "some-media-id")
  end

  test "thumbnail/2 includes query params in both the federation and legacy fallback requests",
       %{port: port, server_name: server_name} do
    FakeRemoteMatrixServer.put_response(
      port,
      {"GET", ~r{^/_matrix/federation/v1/media/thumbnail/}},
      404,
      %{"errcode" => "M_UNRECOGNIZED", "error" => "Unrecognized request"}
    )

    FakeRemoteMatrixServer.put_raw_response(
      port,
      {"GET", ~r{^/_matrix/media/v3/thumbnail/}},
      200,
      "image/png",
      "thumb-bytes"
    )

    assert {:ok, "image/png", "thumb-bytes"} =
             MediaFetch.thumbnail(server_name, "some-media-id", %{
               "width" => "32",
               "height" => "32"
             })

    fed_req =
      Enum.find(FakeRemoteMatrixServer.requests(port), &(&1.path =~ "/media/thumbnail/"))

    legacy_req =
      Enum.find(FakeRemoteMatrixServer.requests(port), &(&1.path =~ "/v3/thumbnail/"))

    assert fed_req.query_string =~ "width=32"
    assert legacy_req.query_string =~ "width=32"
    assert legacy_req.query_string =~ "allow_remote=false"
  end
end

defmodule AxonFederation.MediaFetchTest.RedirectTarget do
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
    |> Plug.Conn.send_resp(200, "redirected-bytes")
  end
end
