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
