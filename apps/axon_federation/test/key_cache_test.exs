defmodule AxonFederation.KeyCacheTest do
  @moduledoc """
  Tests `AxonFederation.KeyCache` against a real `FakeRemoteMatrixServer`.
  """

  use ExUnit.Case, async: false

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}

  @port 18_650
  @server_name "fake-keycache.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()
    Application.put_env(:axon_federation, :server_overrides, %{@server_name => "http://127.0.0.1:#{@port}"})
    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
    :ok
  end

  test "cache miss fetches the key from /_matrix/key/v2/server and returns the right bytes" do
    key_id = FakeRemoteMatrixServer.key_id(@port)
    expected = FakeRemoteMatrixServer.public_key_b64(@port) |> Base.decode64!(padding: false)

    assert KeyCache.get_key(@server_name, key_id) == expected
  end

  test "a cache hit avoids a second HTTP fetch" do
    key_id = FakeRemoteMatrixServer.key_id(@port)
    KeyCache.get_key(@server_name, key_id)
    first_count = length(FakeRemoteMatrixServer.requests(@port))

    KeyCache.get_key(@server_name, key_id)
    assert length(FakeRemoteMatrixServer.requests(@port)) == first_count
  end

  test "an unknown key_id for a known server returns nil, not a crash" do
    assert KeyCache.get_key(@server_name, "ed25519:bogus") == nil
  end

  test "an unreachable server returns nil rather than raising" do
    Application.put_env(:axon_federation, :server_overrides, %{@server_name => "http://127.0.0.1:1"})
    assert KeyCache.get_key(@server_name, "ed25519:whatever") == nil
  end

  test "a malformed key document (bad base64) is handled without crashing" do
    FakeRemoteMatrixServer.put_response(@port, {"GET", "/_matrix/key/v2/server"}, 200, %{
      "server_name" => @server_name,
      "valid_until_ts" => System.os_time(:millisecond) + 60_000,
      "verify_keys" => %{"ed25519:bad" => %{"key" => "not valid base64!!"}}
    })

    assert KeyCache.get_key(@server_name, "ed25519:bad") == nil
  end

  # KNOWN GAP (not fixed here — flagged per plan's fix-small-flag-big policy):
  # KeyCache.cache_key_doc/2 never verifies the fetched key document's own
  # self-signature, nor checks the document's "server_name" field matches the
  # server it was fetched from — it just decodes verify_keys and caches them.
  # This means a compromised/misconfigured intermediary on the fetch path
  # could hand axon an attacker-controlled key with no detection. A real
  # server would sign this response (as AxonCrypto.KeyServer.server_key_info/0
  # and FakeRemoteMatrixServer both do) specifically so it CAN be verified —
  # nothing in axon currently does that verification. This test documents the
  # current (weak) behavior; fixing it is a security-posture decision for the
  # user to make explicitly, not a drive-by patch.
  test "documents that a validly-shaped but unsigned/mismatched-server_name key doc is accepted uncritically" do
    FakeRemoteMatrixServer.put_response(@port, {"GET", "/_matrix/key/v2/server"}, 200, %{
      "server_name" => "totally-different-server.example",
      "valid_until_ts" => System.os_time(:millisecond) + 60_000,
      "verify_keys" => %{"ed25519:unverified" => %{"key" => Base.encode64(:crypto.strong_rand_bytes(32), padding: false)}},
      "signatures" => %{}
    })

    assert KeyCache.get_key(@server_name, "ed25519:unverified") != nil
  end
end
