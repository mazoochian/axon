defmodule AxonWeb.Plug.FederationAuthTest do
  @moduledoc """
  Tests `AxonWeb.Plug.FederationAuth` (X-Matrix signature verification for
  inbound federation requests) via a real signed counterparty
  (`AxonFederation.FakeRemoteMatrixServer`), driving requests through the
  real router at `GET /_matrix/federation/v1/event/:event_id` (a route that
  always reaches the plug regardless of whether the event exists).
  """

  use AxonWeb.ConnCase, async: false

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}

  @port 18_800
  @server_name "fake-fedauth.test"
  @path "/_matrix/federation/v1/event/testevent123"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()
    Application.put_env(:axon_federation, :server_overrides, %{@server_name => "http://127.0.0.1:#{@port}"})
    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
    :ok
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "a validly signed request is accepted and reaches the controller" do
    header = FakeRemoteMatrixServer.sign_request(@port, "GET", @path)

    conn = build_conn() |> put_req_header("authorization", header) |> get(@path)

    # Reaches the controller (M_NOT_FOUND for the nonexistent event) rather
    # than being halted by the auth plug (which would be M_UNAUTHORIZED/401).
    assert conn.status == 404
    assert decode(conn)["errcode"] == "M_NOT_FOUND"
  end

  test "a missing Authorization header is rejected" do
    conn = build_conn() |> get(@path)
    assert conn.status == 401
    assert decode(conn)["errcode"] == "M_UNAUTHORIZED"
  end

  test "a malformed X-Matrix header (missing required params) is rejected" do
    conn = build_conn() |> put_req_header("authorization", "X-Matrix origin=\"#{@server_name}\"") |> get(@path)
    assert conn.status == 401
  end

  test "a header that isn't X-Matrix-scheme at all is rejected" do
    conn = build_conn() |> put_req_header("authorization", "Bearer sometoken") |> get(@path)
    assert conn.status == 401
  end

  test "a request whose destination doesn't match this server's name is rejected" do
    header = FakeRemoteMatrixServer.sign_request(@port, "GET", @path)
    # Corrupt just the destination param, leaving a validly-formatted but wrong-destination header.
    bad_header = String.replace(header, ~s(destination="localhost"), ~s(destination="somewhere-else.test"))

    conn = build_conn() |> put_req_header("authorization", bad_header) |> get(@path)
    assert conn.status == 401
  end

  test "a tampered signature (body doesn't match what was signed) is rejected" do
    header = FakeRemoteMatrixServer.sign_request(@port, "GET", @path <> "different-path")
    conn = build_conn() |> put_req_header("authorization", header) |> get(@path)
    assert conn.status == 401
  end

  test "an origin whose key server can't be reached is rejected" do
    Application.put_env(:axon_federation, :server_overrides, %{@server_name => "http://127.0.0.1:1"})
    header = FakeRemoteMatrixServer.sign_request(@port, "GET", @path)

    conn = build_conn() |> put_req_header("authorization", header) |> get(@path)
    assert conn.status == 401
  end

  test "a signature made with the wrong keypair (right key_id claimed) is rejected" do
    header = FakeRemoteMatrixServer.sign_request(@port, "GET", @path)
    # Swap in a bogus signature while keeping origin/destination/key_id intact.
    bogus_sig = :crypto.strong_rand_bytes(64) |> Base.encode64(padding: false)
    tampered = Regex.replace(~r/sig="[^"]*"/, header, ~s(sig="#{bogus_sig}"))

    conn = build_conn() |> put_req_header("authorization", tampered) |> get(@path)
    assert conn.status == 401
  end
end
