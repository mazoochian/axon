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
      # Unpadded Base64 — the standard RFC 4648 alphabet with the padding
      # stripped, which is what the spec names for `hashes.sha256`. This
      # used to assert the URL-safe alphabet, which is what room versions
      # 4+ use for an *event id* and is a different encoding; the two agree
      # only for the roughly one digest in four containing no byte-triple
      # that encodes to `+` or `/`.
      assert String.match?(hash1, ~r{^[A-Za-z0-9+/]+$})
      refute String.ends_with?(hash1, "=")
      assert {:ok, raw} = Base.decode64(hash1, padding: false)
      assert byte_size(raw) == 32
    end

    test "encodes a digest containing both + and / rather than escaping them" do
      # Find an event whose digest actually exercises the two characters
      # the URL-safe alphabet would have rewritten — otherwise this passes
      # for free on most inputs.
      hash =
        Enum.find_value(1..500, fn n ->
          h = EventHash.content_hash(%{"content" => %{"body" => "probe #{n}"}})
          if String.contains?(h, "+") and String.contains?(h, "/"), do: h
        end)

      assert is_binary(hash), "no probe produced a digest exercising both + and /"
      refute String.contains?(hash, "-")
      refute String.contains?(hash, "_")
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

  describe "verify_content_hash/1" do
    defp hashed(event), do: Map.put(event, "hashes", %{"sha256" => EventHash.content_hash(event)})

    test "accepts an event whose hash matches the content it carries" do
      event = hashed(%{"type" => "m.room.message", "content" => %{"body" => "hello"}})
      assert :ok == EventHash.verify_content_hash(event)
    end

    test "rejects an event whose content changed after the hash was taken" do
      event = hashed(%{"type" => "m.room.message", "content" => %{"body" => "hello"}})
      tampered = put_in(event, ["content", "body"], "goodbye")

      assert {:error, :content_hash_mismatch} == EventHash.verify_content_hash(tampered)
    end

    test "ignores unsigned, signatures and event_id, which are not covered by the hash" do
      # All three are legitimately added or rewritten in transit — `unsigned`
      # by every relaying server, `signatures` by anyone counter-signing,
      # `event_id` by this server itself in send_transaction/2 before the
      # PDU ever reaches verification. Failing the hash on any of them would
      # redact essentially every inbound event.
      event = hashed(%{"type" => "m.room.message", "content" => %{"body" => "hello"}})

      decorated =
        event
        |> Map.put("unsigned", %{"age" => 4321})
        |> Map.put("signatures", %{"relay.test" => %{"ed25519:1" => "sig"}})
        |> Map.put("event_id", "$abc")

      assert :ok == EventHash.verify_content_hash(decorated)
    end

    test "accepts a hash spelled in URL-safe base64 as well as the spec's standard alphabet" do
      event = %{"type" => "m.room.message", "content" => %{"body" => "hello"}}

      url_safe =
        event
        |> EventHash.content_hash()
        |> Base.decode64!(padding: false)
        |> Base.url_encode64(padding: false)

      assert :ok ==
               EventHash.verify_content_hash(Map.put(event, "hashes", %{"sha256" => url_safe}))
    end

    test "an event with no hashes at all, or an unparseable one, fails" do
      event = %{"type" => "m.room.message", "content" => %{"body" => "hello"}}

      assert {:error, :missing_content_hash} == EventHash.verify_content_hash(event)

      assert {:error, :missing_content_hash} ==
               EventHash.verify_content_hash(Map.put(event, "hashes", %{}))

      assert {:error, :missing_content_hash} ==
               EventHash.verify_content_hash(Map.put(event, "hashes", %{"sha256" => 42}))

      assert {:error, :content_hash_mismatch} ==
               EventHash.verify_content_hash(
                 Map.put(event, "hashes", %{"sha256" => "not base64!!"})
               )
    end
  end

  describe "reference_hash/2" do
    test "returns string starting with $" do
      event = %{"type" => "m.room.message", "content" => %{"body" => "hello"}}
      ref = EventHash.reference_hash(event, "11")
      assert String.starts_with?(ref, "$")
    end

    test "removes only unsigned before hashing" do
      event = %{
        "type" => "m.room.message",
        "signatures" => %{"example.com" => %{"ed25519:abc" => "sig"}},
        "unsigned" => %{"age" => 1000}
      }

      # reference hash keeps signatures but strips unsigned
      ref = EventHash.reference_hash(event, "11")
      assert String.starts_with?(ref, "$")

      # Without unsigned the hash should be the same
      ref2 = EventHash.reference_hash(Map.delete(event, "unsigned"), "11")
      assert ref == ref2
    end

    test "different events have different reference hashes" do
      # The reference hash is over the REDACTED event, so a message's body is
      # not directly part of it — two messages differing only in body redact
      # to identical content. What still separates them is `hashes.sha256`,
      # which is computed over the *unredacted* event and survives redaction
      # as a top-level key. Every real event carries one (EventBuilder sets it
      # before signing), so this test builds them the way a real event is.
      e1 = %{"room_id" => "!a:s", "type" => "m.room.message", "content" => %{"body" => "hello"}}
      e2 = %{"room_id" => "!a:s", "type" => "m.room.message", "content" => %{"body" => "world"}}

      e1 = Map.put(e1, "hashes", %{"sha256" => EventHash.content_hash(e1)})
      e2 = Map.put(e2, "hashes", %{"sha256" => EventHash.content_hash(e2)})

      assert EventHash.reference_hash(e1, "11") != EventHash.reference_hash(e2, "11")
    end

    test "is computed over the redacted event, so redaction preserves the event id" do
      # This is the property the whole redact-before-hashing rule exists for:
      # redacting an event must not change its id, or a redacted event could
      # never be matched up with the original.
      event = %{
        "room_id" => "!a:s",
        "type" => "m.room.member",
        "sender" => "@a:s",
        "state_key" => "@a:s",
        "content" => %{"membership" => "join", "displayname" => "Alice"},
        "depth" => 3
      }

      event = Map.put(event, "hashes", %{"sha256" => EventHash.content_hash(event)})
      redacted = AxonCrypto.Redaction.redact(event, "11")

      assert EventHash.reference_hash(event, "11") == EventHash.reference_hash(redacted, "11")
    end
  end

  describe "sign_event/5 and verify_signature/5" do
    setup do
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, public_key: public_key, private_key: private_key}
    end

    test "round-trip sign and verify", %{public_key: pub, private_key: priv} do
      event = %{"type" => "m.room.message", "content" => %{"body" => "hi"}}
      signed = EventHash.sign_event(event, "example.com", "ed25519:abc", priv, "11")

      assert Map.has_key?(signed["signatures"], "example.com")
      assert Map.has_key?(signed["signatures"]["example.com"], "ed25519:abc")

      assert :ok == EventHash.verify_signature(signed, "example.com", "ed25519:abc", pub, "11")
    end

    test "wrong key fails verification", %{private_key: priv} do
      {other_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
      event = %{"type" => "m.room.message"}
      signed = EventHash.sign_event(event, "example.com", "ed25519:abc", priv, "11")

      assert {:error, :invalid_signature} ==
               EventHash.verify_signature(signed, "example.com", "ed25519:abc", other_pub, "11")
    end

    test "missing signature returns error", %{public_key: pub} do
      event = %{"type" => "m.room.message"}

      assert {:error, :missing_signature} ==
               EventHash.verify_signature(event, "example.com", "ed25519:abc", pub, "11")
    end

    test "signature is invalidated if a signed field changes", %{
      public_key: pub,
      private_key: priv
    } do
      # Tamper with a field that SURVIVES redaction. A message body does not:
      # it is redacted away before signing, precisely so that redacting an
      # event later keeps its signature valid. Asserting on a body here would
      # have been asserting the opposite of the spec's intent.
      event = %{
        "type" => "m.room.member",
        "sender" => "@a:s",
        "content" => %{"membership" => "join"}
      }

      signed = EventHash.sign_event(event, "example.com", "ed25519:abc", priv, "11")
      tampered = put_in(signed, ["content", "membership"], "leave")

      assert {:error, :invalid_signature} ==
               EventHash.verify_signature(tampered, "example.com", "ed25519:abc", pub, "11")
    end

    test "a signature survives redaction of the event it signed", %{
      public_key: pub,
      private_key: priv
    } do
      event = %{
        "type" => "m.room.member",
        "sender" => "@a:s",
        "state_key" => "@a:s",
        "content" => %{"membership" => "join", "displayname" => "Alice"}
      }

      signed = EventHash.sign_event(event, "example.com", "ed25519:abc", priv, "11")
      redacted = AxonCrypto.Redaction.redact(signed, "11")

      assert :ok == EventHash.verify_signature(redacted, "example.com", "ed25519:abc", pub, "11")
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
      signed = EventHash.sign_event(event, "example.com", "ed25519:abc", priv, "11")
      event_id = EventHash.reference_hash(signed, "11")
      with_event_id = Map.put(signed, "event_id", event_id)

      assert :ok == EventHash.verify_signature(with_event_id, "example.com", "ed25519:abc", pub, "11")
    end
  end
end
