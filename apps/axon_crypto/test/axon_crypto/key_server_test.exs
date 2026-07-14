defmodule AxonCrypto.KeyServerTest do
  @moduledoc """
  Direct unit tests for `AxonCrypto.KeyServer` — previously only ever
  exercised indirectly through other apps' integration tests (it has no
  supervision tree of its own in axon_crypto, so nothing here started it
  before now).
  """

  use ExUnit.Case, async: true

  alias AxonCrypto.{CanonicalJSON, EventHash, KeyServer}

  setup do
    name = :"key_server_test_#{System.unique_integer([:positive])}"
    server_name = "test-server-#{System.unique_integer([:positive])}.example.org"

    # KeyServer registers itself under its own module name (not the `name`
    # option), so tests must run isolated GenServers directly rather than
    # through the public API, which always targets AxonCrypto.KeyServer.
    {:ok, pid} = GenServer.start_link(KeyServer, [server_name: server_name], name: name)
    %{pid: pid, server_name: server_name}
  end

  describe "generate_keypair/0" do
    test "returns a well-formed key_id and 32-byte Ed25519 keys" do
      {key_id, public_key, private_key} = KeyServer.generate_keypair()

      assert String.starts_with?(key_id, "ed25519:")
      assert byte_size(public_key) == 32
      assert byte_size(private_key) == 32
    end

    test "generates distinct keys on every call" do
      {id1, pub1, _} = KeyServer.generate_keypair()
      {id2, pub2, _} = KeyServer.generate_keypair()

      refute id1 == id2
      refute pub1 == pub2
    end
  end

  describe "server_name/0" do
    test "returns the configured server name", %{pid: pid, server_name: server_name} do
      assert GenServer.call(pid, :server_name) == server_name
    end
  end

  describe "server_key_info/0 (via handle_call)" do
    test "returns a self-signed key document verifiable against its own public key", %{
      pid: pid,
      server_name: server_name
    } do
      info = GenServer.call(pid, :server_key_info)

      assert info.server_name == server_name
      assert String.starts_with?(info.key_id, "ed25519:")
      assert is_binary(info.public_key_b64)
      assert info.valid_until_ts > System.os_time(:millisecond)

      sig_b64 = info.signatures[server_name][info.key_id]
      assert is_binary(sig_b64)

      # Reconstruct the exact document that was signed and verify it.
      unsigned_doc = %{
        "server_name" => info.server_name,
        "valid_until_ts" => info.valid_until_ts,
        "verify_keys" => %{info.key_id => %{"key" => info.public_key_b64}}
      }

      {:ok, pub_key} = Base.decode64(info.public_key_b64, padding: false)
      {:ok, sig_bytes} = Base.decode64(sig_b64, padding: false)
      payload = CanonicalJSON.encode_to_binary(unsigned_doc)

      assert :crypto.verify(:eddsa, :none, payload, sig_bytes, [pub_key, :ed25519])
    end

    test "valid_until_ts is roughly 7 days out", %{pid: pid} do
      info = GenServer.call(pid, :server_key_info)
      seven_days_ms = 7 * 24 * 60 * 60 * 1000
      now = System.os_time(:millisecond)

      assert_in_delta info.valid_until_ts, now + seven_days_ms, 5_000
    end
  end

  describe "sign/1 (via handle_call)" do
    test "produces a signature verifiable against the server's own public key", %{pid: pid} do
      payload = "arbitrary bytes to sign"
      {key_id, sig_b64} = GenServer.call(pid, {:sign, payload})

      info = GenServer.call(pid, :server_key_info)
      assert key_id == info.key_id

      {:ok, pub_key} = Base.decode64(info.public_key_b64, padding: false)
      {:ok, sig_bytes} = Base.decode64(sig_b64, padding: false)

      assert :crypto.verify(:eddsa, :none, payload, sig_bytes, [pub_key, :ed25519])
    end

    test "different payloads produce different signatures", %{pid: pid} do
      {_key_id, sig1} = GenServer.call(pid, {:sign, "payload one"})
      {_key_id, sig2} = GenServer.call(pid, {:sign, "payload two"})
      refute sig1 == sig2
    end
  end

  describe "sign_event/1 (via handle_call)" do
    test "signs an event map such that EventHash.verify_signature/4 accepts it", %{
      pid: pid,
      server_name: server_name
    } do
      event = %{"type" => "m.room.message", "content" => %{"body" => "hello"}}
      signed = GenServer.call(pid, {:sign_event, event})

      info = GenServer.call(pid, :server_key_info)
      {:ok, pub_key} = Base.decode64(info.public_key_b64, padding: false)

      assert :ok = EventHash.verify_signature(signed, server_name, info.key_id, pub_key)
    end

    test "the signed event's non-signature fields are unchanged", %{pid: pid} do
      event = %{"type" => "m.room.message", "content" => %{"body" => "hello"}, "depth" => 3}
      signed = GenServer.call(pid, {:sign_event, event})

      assert signed["type"] == "m.room.message"
      assert signed["content"] == %{"body" => "hello"}
      assert signed["depth"] == 3
      assert Map.has_key?(signed, "signatures")
    end
  end
end
