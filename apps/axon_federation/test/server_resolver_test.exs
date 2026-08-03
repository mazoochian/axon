defmodule AxonFederation.ServerResolverTest do
  use ExUnit.Case, async: false

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache, ServerResolver}

  setup do
    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
    :ok
  end

  test "override takes priority when present" do
    Application.put_env(:axon_federation, :server_overrides, %{
      "fake.test" => "http://127.0.0.1:9999"
    })

    assert ServerResolver.resolve("fake.test") == "http://127.0.0.1:9999"
  end

  test "falls back to :8448 when no override and well-known is unreachable" do
    assert ServerResolver.resolve("nonexistent-#{System.unique_integer([:positive])}.invalid") =~
             ":8448"
  end

  # Regression: a server_name carrying an explicit port used to always fall
  # through to resolve_via_well_known, which — on a failed/unreachable
  # .well-known fetch — appended a *second*, default ":8448" on top of the
  # port already in server_name, producing a malformed double-port
  # authority (e.g. "https://127.0.0.1:1:8448") that Finch can't parse.
  # This was invisible until something actually resolved an explicit-port
  # server_name through this path (previously only override/no-port names
  # exercised it in practice).
  test "an explicit-port server_name is used as-is, no well-known lookup, no double :8448" do
    assert ServerResolver.resolve("127.0.0.1:1") == "https://127.0.0.1:1"
    assert ServerResolver.resolve("example.org:9999") == "https://example.org:9999"
  end

  test "an explicit-port server_name skips well-known even if a matching bare-name override exists" do
    # sanity: only exact server_name keys hit the override map, port or not
    Application.put_env(:axon_federation, :server_overrides, %{"hs2" => "http://127.0.0.1:1"})
    assert ServerResolver.resolve("hs2:8449") == "https://hs2:8449"
  end

  test "a real fake server is reachable via the override and serves a self-signed key doc" do
    port = 18_400
    server_name = "fake-#{System.unique_integer([:positive])}.test"

    start_supervised!({FakeRemoteMatrixServer, port: port, server_name: server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      server_name => "http://127.0.0.1:#{port}"
    })

    key_id = FakeRemoteMatrixServer.key_id(port)
    pub_key = KeyCache.get_key(server_name, key_id)

    assert pub_key ==
             FakeRemoteMatrixServer.public_key_b64(port) |> Base.decode64!(padding: false)
  end
end
