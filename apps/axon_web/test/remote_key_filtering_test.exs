defmodule AxonWeb.RemoteKeyFilteringTest do
  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}

  @port 18_991
  @server_name "fake-keys.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)

    alice = register("rkf_#{System.unique_integer([:positive])}")
    %{alice: alice, remote_user: "@bob:#{@server_name}"}
  end

  defp fake_key(user_id, key_id),
    do: %{"user_id" => user_id, "keys" => %{"ed25519:#{key_id}" => "k"}, "signatures" => %{}}

  test "keys/query ignores remote entries for users that server wasn't asked about", ctx do
    %{alice: alice, remote_user: bob} = ctx

    FakeRemoteMatrixServer.put_response(
      @port,
      {"POST", ~r{^/_matrix/federation/v1/user/keys/query}},
      200,
      %{
        "device_keys" => %{
          alice.user_id => %{"EVIL" => fake_key(alice.user_id, "EVIL")},
          bob => %{"BOBDEV" => fake_key(bob, "BOBDEV"), "BAD" => "not-an-object"}
        },
        "master_keys" => %{alice.user_id => fake_key(alice.user_id, "EVILMASTER")},
        "self_signing_keys" => %{bob => "not-an-object"}
      }
    )

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/keys/query", %{
        "device_keys" => %{alice.user_id => [], bob => []}
      })

    assert conn.status == 200
    body = decode(conn)
    refute Map.has_key?(body["device_keys"][alice.user_id], "EVIL")
    assert Map.keys(body["device_keys"][bob]) == ["BOBDEV"]
    refute Map.has_key?(body["master_keys"], alice.user_id)
    assert body["self_signing_keys"] == %{}
  end

  test "keys/query survives a malformed remote reply", %{alice: alice, remote_user: bob} do
    FakeRemoteMatrixServer.put_response(
      @port,
      {"POST", ~r{^/_matrix/federation/v1/user/keys/query}},
      200,
      %{"device_keys" => [1, 2], "master_keys" => "nope"}
    )

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/keys/query", %{"device_keys" => %{bob => []}})

    assert conn.status == 200
    assert decode(conn)["device_keys"] == %{}
  end

  test "keys/claim ignores remote one-time keys for users not asked of that server", ctx do
    %{alice: alice, remote_user: bob} = ctx

    FakeRemoteMatrixServer.put_response(
      @port,
      {"POST", ~r{^/_matrix/federation/v1/user/keys/claim}},
      200,
      %{
        "one_time_keys" => %{
          alice.user_id => %{"EVIL" => %{"signed_curve25519:x" => %{"key" => "k"}}},
          bob => %{"BOBDEV" => %{"signed_curve25519:y" => %{"key" => "k"}}}
        }
      }
    )

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/keys/claim", %{
        "one_time_keys" => %{bob => %{"BOBDEV" => "signed_curve25519"}}
      })

    assert conn.status == 200
    assert Map.keys(decode(conn)["one_time_keys"]) == [bob]
  end
end
