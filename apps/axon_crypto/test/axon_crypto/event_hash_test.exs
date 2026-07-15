defmodule AxonCrypto.EventHashTest do
  use ExUnit.Case, async: true

  alias AxonCrypto.EventHash

  describe "content_hash/1" do
    test "removes unsigned, signatures, hashes before hashing" do
      event = %{
        "type" => "m.room.message",
        "content" => %{"body" => "hello"},
        "unsigned" => %{"age" => 1000},
        "signatures" => %{"example.com" => %{"ed25519:abc" => "sig"}},
        "hashes" => %{"sha256" => "oldhash"}
      }

      # Should produce a stable hash (unsigned/signatures/hashes stripped)
      hash1 = EventHash.content_hash(event)

      event2 = Map.drop(event, ["unsigned", "signatures", "hashes"])
      hash2 = EventHash.content_hash(event2)

      assert hash1 == hash2
      assert is_binary(hash1)
      # base64url without padding
      assert String.match?(hash1, ~r/^[A-Za-z0-9_-]+$/)
    end

    test "same content produces same hash" do
      event = %{"type" => "m.room.message", "content" => %{"body" => "hi"}}
      assert EventHash.content_hash(event) == EventHash.content_hash(event)
    end

    test "different content produces different hash" do
      e1 = %{"content" => %{"body" => "hello"}}
      e2 = %{"content" => %{"body" => "world"}}
      assert EventHash.content_hash(e1) != EventHash.content_hash(e2)
    end
  end

  describe "reference_hash/1" do
    test "returns string starting with $" do
      event = %{"type" => "m.room.message", "content" => %{"body" => "hello"}}
      ref = EventHash.reference_hash(event)
      assert String.starts_with?(ref, "$")
    end

    test "removes only unsigned before hashing" do
      event = %{
        "type" => "m.room.message",
        "signatures" => %{"example.com" => %{"ed25519:abc" => "sig"}},
        "unsigned" => %{"age" => 1000}
      }

      # reference hash keeps signatures but strips unsigned
      ref = EventHash.reference_hash(event)
      assert String.starts_with?(ref, "$")

      # Without unsigned the hash should be the same
      ref2 = EventHash.reference_hash(Map.delete(event, "unsigned"))
      assert ref == ref2
    end

    test "different events have different reference hashes" do
      e1 = %{"room_id" => "!a:s", "content" => %{"body" => "hello"}}
      e2 = %{"room_id" => "!a:s", "content" => %{"body" => "world"}}
      assert EventHash.reference_hash(e1) != EventHash.reference_hash(e2)
    end
  end

  describe "sign_event/4 and verify_signature/4" do
    setup do
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, public_key: public_key, private_key: private_key}
    end

    test "round-trip sign and verify", %{public_key: pub, private_key: priv} do
      event = %{"type" => "m.room.message", "content" => %{"body" => "hi"}}
      signed = EventHash.sign_event(event, "example.com", "ed25519:abc", priv)

      assert Map.has_key?(signed["signatures"], "example.com")
      assert Map.has_key?(signed["signatures"]["example.com"], "ed25519:abc")

      assert :ok == EventHash.verify_signature(signed, "example.com", "ed25519:abc", pub)
    end

    test "wrong key fails verification", %{private_key: priv} do
      {other_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
      event = %{"type" => "m.room.message"}
      signed = EventHash.sign_event(event, "example.com", "ed25519:abc", priv)

      assert {:error, :invalid_signature} ==
               EventHash.verify_signature(signed, "example.com", "ed25519:abc", other_pub)
    end

    test "missing signature returns error", %{public_key: pub} do
      event = %{"type" => "m.room.message"}

      assert {:error, :missing_signature} ==
               EventHash.verify_signature(event, "example.com", "ed25519:abc", pub)
    end

    test "signature is invalidated if event content changes", %{
      public_key: pub,
      private_key: priv
    } do
      event = %{"type" => "m.room.message", "content" => %{"body" => "original"}}
      signed = EventHash.sign_event(event, "example.com", "ed25519:abc", priv)

      tampered = put_in(signed, ["content", "body"], "tampered")

      assert {:error, :invalid_signature} ==
               EventHash.verify_signature(tampered, "example.com", "ed25519:abc", pub)
    end

    test "verification still succeeds once event_id is added after signing (matches EventBuilder's real order of operations)",
         %{public_key: pub, private_key: priv} do
      # EventBuilder.build/5 signs the skeleton BEFORE "event_id" exists on the
      # map, then adds "event_id" (the reference hash) afterward. Any event
      # round-tripped through EventStore.event_to_map/1 always carries
      # "event_id". If verify_signature/4 didn't exclude "event_id" from its
      # signable computation, every axon-produced event would fail
      # re-verification the moment it's fetched back from storage.
      event = %{"type" => "m.room.message", "content" => %{"body" => "hi"}}
      signed = EventHash.sign_event(event, "example.com", "ed25519:abc", priv)
      event_id = EventHash.reference_hash(signed)
      with_event_id = Map.put(signed, "event_id", event_id)

      assert :ok == EventHash.verify_signature(with_event_id, "example.com", "ed25519:abc", pub)
    end
  end
end
