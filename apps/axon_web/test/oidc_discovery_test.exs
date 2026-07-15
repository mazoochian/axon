defmodule AxonWeb.Oidc.DiscoveryTest do
  @moduledoc """
  Direct unit tests for `AxonWeb.Oidc.Discovery`'s fetch/cache GenServer,
  covering the failure branches `AxonWeb.OidcTest`'s controller-level tests
  never exercise (that suite only ever sees the fake AS's well-formed
  discovery document).
  """

  use ExUnit.Case, async: false

  alias AxonWeb.Oidc.Discovery

  setup do
    :ets.delete_all_objects(:oidc_discovery_cache)
    :ok
  end

  test "a cache hit avoids a second network fetch" do
    port = 18_600
    Agent.start_link(fn -> 0 end, name: :discovery_test_hit_counter)
    {:ok, pid} = Bandit.start_link(plug: __MODULE__.OkPlug, ip: {127, 0, 0, 1}, port: port)
    issuer = "http://127.0.0.1:#{port}"

    assert {:ok, doc} = Discovery.metadata(issuer)
    assert doc["issuer"] == issuer
    assert {:ok, ^doc} = Discovery.metadata(issuer)

    assert Agent.get(:discovery_test_hit_counter, & &1) == 1

    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  test "a non-200 status is reported as an http_error" do
    port = 18_601
    {:ok, pid} = Bandit.start_link(plug: __MODULE__.ErrorPlug, ip: {127, 0, 0, 1}, port: port)
    issuer = "http://127.0.0.1:#{port}"

    assert Discovery.metadata(issuer) == {:error, {:http_error, 500}}

    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  test "an invalid JSON body is reported as invalid_json" do
    port = 18_602
    {:ok, pid} = Bandit.start_link(plug: __MODULE__.BadJsonPlug, ip: {127, 0, 0, 1}, port: port)
    issuer = "http://127.0.0.1:#{port}"

    assert Discovery.metadata(issuer) == {:error, :invalid_json}

    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  test "a network error (nothing listening) is passed through as the error reason" do
    issuer = "http://127.0.0.1:1"
    assert {:error, _reason} = Discovery.metadata(issuer)
  end

  defmodule OkPlug do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    get "/.well-known/openid-configuration" do
      Agent.update(:discovery_test_hit_counter, &(&1 + 1))
      body = Jason.encode!(%{"issuer" => "http://127.0.0.1:#{conn.port}"})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule ErrorPlug do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    get "/.well-known/openid-configuration" do
      Plug.Conn.send_resp(conn, 500, "internal error")
    end
  end

  defmodule BadJsonPlug do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    get "/.well-known/openid-configuration" do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "not json{{{")
    end
  end
end
