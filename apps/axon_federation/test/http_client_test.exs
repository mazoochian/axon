defmodule AxonFederation.HttpClientTest do
  @moduledoc """
  Tests `AxonFederation.HttpClient`'s outbound signed request building and
  response parsing against a real `FakeRemoteMatrixServer` on loopback.
  """

  use ExUnit.Case, async: false

  alias AxonFederation.{FakeRemoteMatrixServer, HttpClient, KeyCache}

  @port 18_600
  @server_name "fake-http-client.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()
    Application.put_env(:axon_federation, :server_overrides, %{@server_name => "http://127.0.0.1:#{@port}"})
    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
    :ok
  end

  test "get/2 sends a well-formed X-Matrix authorization header" do
    FakeRemoteMatrixServer.put_response(@port, {"GET", "/_matrix/federation/v1/version"}, 200, %{"server" => %{"name" => "axon"}})

    assert {:ok, %{"server" => %{"name" => "axon"}}} = HttpClient.get(@server_name, "/_matrix/federation/v1/version")

    [%{headers: headers}] = FakeRemoteMatrixServer.requests(@port)
    {_, auth} = Enum.find(headers, fn {k, _} -> k == "authorization" end)
    assert auth =~ ~r/^X-Matrix origin="[^"]+",destination="#{@server_name}",key="[^"]+",sig="[^"]+"$/
  end

  test "put/3 signs the body as part of the request and delivers it" do
    FakeRemoteMatrixServer.put_response(@port, {"PUT", "/_matrix/federation/v1/send/txn1"}, 200, %{})

    assert {:ok, %{}} = HttpClient.put(@server_name, "/_matrix/federation/v1/send/txn1", %{"pdus" => []})

    [%{body: body}] = FakeRemoteMatrixServer.requests(@port)
    assert body == %{"pdus" => []}
  end

  test "post/3 works the same as put for signing/delivery" do
    FakeRemoteMatrixServer.put_response(@port, {"POST", "/_matrix/federation/v1/get_missing_events/!room:x"}, 200, %{"events" => []})

    assert {:ok, %{"events" => []}} =
             HttpClient.post(@server_name, "/_matrix/federation/v1/get_missing_events/!room:x", %{"limit" => 10})
  end

  test "a non-2xx response with a Matrix error body surfaces {errcode, error}" do
    FakeRemoteMatrixServer.put_response(@port, {"GET", "/_matrix/federation/v1/notfound"}, 404, %{"errcode" => "M_NOT_FOUND", "error" => "no such thing"})

    assert HttpClient.get(@server_name, "/_matrix/federation/v1/notfound") == {:error, {"M_NOT_FOUND", "no such thing"}}
  end

  test "a non-2xx response without a Matrix error body surfaces the raw status" do
    FakeRemoteMatrixServer.put_response(@port, {"GET", "/_matrix/federation/v1/broken"}, 500, %{"unexpected" => "shape"})

    assert HttpClient.get(@server_name, "/_matrix/federation/v1/broken") == {:error, {:http_error, 500}}
  end

  test "an unreachable server surfaces a network error, not a crash" do
    Application.put_env(:axon_federation, :server_overrides, %{@server_name => "http://127.0.0.1:1"})
    assert {:error, _reason} = HttpClient.get(@server_name, "/_matrix/federation/v1/version")
  end
end
