defmodule AxonWeb.IdentityServerTest do
  use ExUnit.Case, async: false

  alias AxonWeb.{FakeIdentityServer, IdentityServer}

  @port 18_710

  setup do
    start_supervised!({FakeIdentityServer, port: @port})
    previous_default = Application.get_env(:axon_web, :default_identity_server)
    previous_allow = Application.get_env(:axon_federation, :allow_private_addresses)

    on_exit(fn ->
      Application.put_env(:axon_federation, :allow_private_addresses, previous_allow)

      if previous_default,
        do: Application.put_env(:axon_web, :default_identity_server, previous_default),
        else: Application.delete_env(:axon_web, :default_identity_server)
    end)

    :ok
  end

  test "a client-supplied id_server must be a bare hostname and is always https" do
    assert IdentityServer.resolve_id_server(%{"id_server" => "id.example.com:8090"}) ==
             {:ok, "https://id.example.com:8090"}

    for bad <- ["http://id.example.com", "id.example.com/path", "a@b", "id.example.com?x=1"] do
      assert IdentityServer.resolve_id_server(%{"id_server" => bad}) == {:error, :invalid_input}
    end
  end

  test "untrusted identity-server URLs on private addresses are refused" do
    Application.put_env(:axon_federation, :allow_private_addresses, false)
    Application.delete_env(:axon_web, :default_identity_server)
    url = FakeIdentityServer.url(@port) <> "/_matrix/identity/v2/pubkey/ephemeral/isvalid"

    refute IdentityServer.pubkey_valid?(url, "key-#{System.unique_integer([:positive])}")

    assert IdentityServer.hash_lookup(FakeIdentityServer.url(@port), nil, "email", "a@b.c") ==
             {:error, :blocked_address}
  end

  test "the operator-configured default identity server may be on a private address" do
    Application.put_env(:axon_federation, :allow_private_addresses, false)
    Application.put_env(:axon_web, :default_identity_server, FakeIdentityServer.url(@port))
    url = FakeIdentityServer.url(@port) <> "/_matrix/identity/v2/pubkey/ephemeral/isvalid"

    assert IdentityServer.pubkey_valid?(url, "key-#{System.unique_integer([:positive])}")
  end
end
