defmodule AxonFederation.EventVerificationTest do
  @moduledoc """
  `AxonFederation.EventVerification` — the single signature check standing
  between an inbound PDU and this server's room state.

  It used to choose *which server's key to verify against* from the event's
  own `origin` field. Every federating server's signing key is public and
  fetchable, so that made cross-server impersonation a matter of setting one
  string: an attacker running `evil.test` writes `sender = @victim:good.test`,
  sets `origin = "evil.test"`, and signs with `evil.test`'s own key.
  Verification looked up `evil.test`'s key — the key that really did sign —
  found the signature valid, and accepted the event as authentic though
  `good.test` never touched it.

  Both servers here are real `FakeRemoteMatrixServer` instances with real
  Ed25519 keypairs, serving real `/_matrix/key/v2/server` documents that
  `KeyCache` really fetches over HTTP, and the signatures are produced by
  the same `AxonCrypto.EventHash` code production signs with. The forgery is
  genuinely valid crypto — it is rejected because of *whose* key it is, not
  because anything about it is malformed.
  """

  use ExUnit.Case, async: false

  alias AxonFederation.{EventVerification, FakeRemoteMatrixServer, KeyCache}

  setup do
    good_port = 18_700 + System.unique_integer([:positive, :monotonic])
    evil_port = 18_800 + System.unique_integer([:positive, :monotonic])
    good = "good-#{System.unique_integer([:positive])}.test"
    evil = "evil-#{System.unique_integer([:positive])}.test"

    start_supervised!({FakeRemoteMatrixServer, port: good_port, server_name: good})
    start_supervised!({FakeRemoteMatrixServer, port: evil_port, server_name: evil})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      good => "http://127.0.0.1:#{good_port}",
      evil => "http://127.0.0.1:#{evil_port}"
    })

    on_exit(fn ->
      Application.delete_env(:axon_federation, :server_overrides)
      KeyCache.clear()
    end)

    %{good: good, good_port: good_port, evil: evil, evil_port: evil_port}
  end

  defp base_event(sender) do
    %{
      "room_id" => "!room_#{System.unique_integer([:positive])}:localhost",
      "type" => "m.room.message",
      "sender" => sender,
      "content" => %{"msgtype" => "m.text", "body" => "I never said this"},
      "depth" => 5,
      "prev_events" => [],
      "auth_events" => [],
      "origin_server_ts" => System.os_time(:millisecond),
      "hashes" => %{"sha256" => "x"}
    }
  end

  test "an event whose sender is on another server, signed only by the attacker, is rejected",
       %{good: good, evil: evil, evil_port: evil_port} do
    forged =
      base_event("@victim:#{good}")
      |> Map.put("origin", evil)
      |> then(&FakeRemoteMatrixServer.sign_event(evil_port, &1, "11"))

    # The forgery really is cryptographically sound as far as evil's key
    # goes — this is not a malformed-signature test.
    assert get_in(forged, ["signatures", evil]) != nil
    assert get_in(forged, ["signatures", good]) == nil

    assert {:error, :missing_signature} = EventVerification.verify_signature(forged, "11")
  end

  test "a legitimate event signed by the sender's own server verifies",
       %{good: good, good_port: good_port} do
    legit =
      base_event("@alice:#{good}")
      |> Map.put("origin", good)
      |> then(&FakeRemoteMatrixServer.sign_event(good_port, &1, "11"))

    assert :ok = EventVerification.verify_signature(legit, "11")
  end

  test "an event with no origin field at all still verifies against the sender's server",
       %{good: good, good_port: good_port} do
    legit =
      base_event("@alice:#{good}")
      |> then(&FakeRemoteMatrixServer.sign_event(good_port, &1, "11"))

    refute Map.has_key?(legit, "origin")
    assert :ok = EventVerification.verify_signature(legit, "11")
  end

  # `origin` is now inert for key selection in both directions: it can't
  # point verification at the wrong server, and a bogus value on an
  # otherwise-genuine event can't get that event rejected either. (Room
  # version 11 drops `origin` in redaction, so adding it doesn't disturb the
  # signature — which is exactly why a v11 attacker could set it freely.)
  test "a genuine event is still accepted when the attacker rewrites its origin",
       %{good: good, good_port: good_port, evil: evil} do
    tampered =
      base_event("@alice:#{good}")
      |> then(&FakeRemoteMatrixServer.sign_event(good_port, &1, "11"))
      |> Map.put("origin", evil)

    assert :ok = EventVerification.verify_signature(tampered, "11")
  end

  test "an attacker's extra signature alongside the sender's real one changes nothing",
       %{good: good, good_port: good_port, evil_port: evil_port} do
    doubly_signed =
      base_event("@alice:#{good}")
      |> then(&FakeRemoteMatrixServer.sign_event(good_port, &1, "11"))
      |> then(&FakeRemoteMatrixServer.sign_event(evil_port, &1, "11"))

    assert :ok = EventVerification.verify_signature(doubly_signed, "11")
  end

  test "a signature entry under the sender's domain that doesn't verify is rejected",
       %{good: good, good_port: good_port} do
    event = base_event("@alice:#{good}")
    signed = FakeRemoteMatrixServer.sign_event(good_port, event, "11")

    tampered =
      put_in(signed, ["content", "body"], "a body the sender never signed")
      # v11 redaction strips `content` from m.room.message, so the body
      # alone wouldn't break the signature — change something that survives
      # redaction too.
      |> Map.put("depth", 6)

    assert {:error, :bad_signature} = EventVerification.verify_signature(tampered, "11")
  end

  test "an event with no sender is rejected rather than defaulting to anything" do
    event = base_event("@alice:whatever.test") |> Map.delete("sender")
    assert {:error, :missing_sender} = EventVerification.verify_signature(event, "11")
  end

  test "a sender on a server whose keys can't be fetched is rejected" do
    unknown = "never-heard-of-#{System.unique_integer([:positive])}.test"

    event =
      base_event("@alice:#{unknown}")
      |> Map.put("signatures", %{unknown => %{"ed25519:a_key" => "AAAA"}})

    assert {:error, :key_not_found} = EventVerification.verify_signature(event, "11")
  end

  # ---------------------------------------------------------------------------
  # verify/2 — signature *and* content hash, with the spec's asymmetric
  # failure modes: a bad signature drops the event, a bad content hash
  # redacts it. See the moduledoc on AxonFederation.EventVerification.
  # ---------------------------------------------------------------------------

  describe "verify/2" do
    test "returns an untouched event when both checks pass",
         %{good: good, good_port: good_port} do
      legit =
        base_event("@alice:#{good}")
        |> then(&FakeRemoteMatrixServer.sign_event(good_port, &1, "11"))

      assert {:ok, verified} = EventVerification.verify(legit, "11")
      assert verified == legit
      assert verified["content"]["body"] == "I never said this"
    end

    test "returns the redacted event when the content hash doesn't match",
         %{good: good, good_port: good_port} do
      tampered =
        base_event("@alice:#{good}")
        |> then(&FakeRemoteMatrixServer.sign_event(good_port, &1, "11"))
        |> put_in(["content", "body"], "a body a relaying server substituted")

      # The signature is still perfectly valid — v11 redaction strips
      # `content` from an m.room.message, so the body was never signed.
      # Only the content hash notices.
      assert :ok = EventVerification.verify_signature(tampered, "11")

      assert {:ok, verified} = EventVerification.verify(tampered, "11")
      assert verified["content"] == %{}
      assert verified["sender"] == tampered["sender"]
      assert verified["signatures"] == tampered["signatures"]
    end

    test "a bad signature is an error, not a redaction",
         %{good: good, good_port: good_port} do
      tampered =
        base_event("@alice:#{good}")
        |> then(&FakeRemoteMatrixServer.sign_event(good_port, &1, "11"))
        |> Map.put("depth", 6)

      assert {:error, :bad_signature} = EventVerification.verify(tampered, "11")
    end

    test "event_id survives the redaction, even in a room version that drops it",
         %{good: good, good_port: good_port} do
      # Room version 11's redaction algorithm doesn't list `event_id` among
      # the surviving top-level keys (it isn't a real wire field there — it's
      # the reference hash). Everything downstream of verification, right
      # through to EventStore.insert_event/2's NOT NULL column, still needs
      # it on the map.
      tampered =
        base_event("@alice:#{good}")
        |> Map.put("event_id", "$known_id_#{System.unique_integer([:positive])}")
        |> then(&FakeRemoteMatrixServer.sign_event(good_port, &1, "11"))
        |> put_in(["content", "body"], "rewritten")

      assert {:ok, verified} = EventVerification.verify(tampered, "11")
      assert verified["event_id"] == tampered["event_id"]
    end

    test "a room version that keeps event_id through redaction keeps it too",
         %{good: good, good_port: good_port} do
      tampered =
        base_event("@alice:#{good}")
        |> Map.put("event_id", "$v10_id_#{System.unique_integer([:positive])}")
        |> then(&FakeRemoteMatrixServer.sign_event(good_port, &1, "10"))
        |> put_in(["content", "body"], "rewritten")

      assert {:ok, verified} = EventVerification.verify(tampered, "10")
      assert verified["event_id"] == tampered["event_id"]
      assert verified["content"] == %{}
    end
  end

  describe "verify_signature_from/3" do
    test "asks about one named server, for callers needing an additional signature",
         %{good: good, good_port: good_port, evil: evil, evil_port: evil_port} do
      event =
        base_event("@alice:#{good}")
        |> then(&FakeRemoteMatrixServer.sign_event(good_port, &1, "11"))
        |> then(&FakeRemoteMatrixServer.sign_event(evil_port, &1, "11"))

      assert :ok = EventVerification.verify_signature_from(event, good, "11")
      assert :ok = EventVerification.verify_signature_from(event, evil, "11")

      assert {:error, :missing_signature} =
               EventVerification.verify_signature_from(event, "third-party.test", "11")
    end
  end
end
