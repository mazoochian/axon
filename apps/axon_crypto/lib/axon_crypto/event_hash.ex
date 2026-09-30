defmodule AxonCrypto.EventHash do
  @moduledoc """
  Matrix event hashing and signing.

  Spec: https://spec.matrix.org/latest/server-server-api/#calculating-the-content-hash-for-an-event
  """

  alias AxonCrypto.{CanonicalJSON, Redaction}

  # "event_id" is never part of any of these hashable/signable computations:
  # for room versions 3+ it isn't a real event field at all (it's derived —
  # see reference_hash/1 below), and even where a caller's event map happens
  # to already carry one (e.g. AxonCore.EventStore.event_to_map/1 always
  # adds it for internal/API convenience), the ORIGINAL signature was
  # computed before "event_id" existed on the map. Not excluding it here
  # made every signature axon itself produces fail its own re-verification
  # the moment "event_id" was present — which is always, for any event
  # that's round-tripped through the DB — and would do the same for any
  # other spec-compliant server trying to verify axon's outbound PDUs.
  @non_content_fields ["unsigned", "signatures", "event_id"]

  @doc """
  Computes the content hash of an event (for the `hashes.sha256` field).

  Remove unsigned, signatures, hashes from the event first, then SHA256 the canonical JSON.

  The result is **Unpadded Base64** — the standard RFC 4648 alphabet with
  the `=` padding stripped, which is what the spec names for this field
  ("The Unpadded Base64 encoded key"). This used to emit *URL-safe* base64
  (`-`/`_` in place of `+`/`/`), which is the encoding room versions 4+ use
  for the reference hash in an event ID and is a different thing. A SHA-256
  digest contains at least one byte-triple encoding to `+` or `/` roughly
  three times out of four, so three quarters of the content hashes this
  server put on the wire disagreed, character for character, with what a
  spec-compliant peer recomputes — and a peer that checks content hashes
  (Synapse does) answers a mismatch by *redacting* the event, silently
  stripping the body off most outbound messages. Verification here decodes
  before comparing (see `verify_content_hash/1`) so it stays tolerant of
  either alphabet on the way in regardless.
  """
  @spec content_hash(map()) :: binary()
  def content_hash(event) do
    event
    |> content_hash_payload()
    |> CanonicalJSON.encode_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode64(padding: false)
  end

  @doc """
  Checks an event's own `hashes.sha256` against a freshly computed content
  hash. `:ok`, or `{:error, :missing_content_hash | :content_hash_mismatch}`
  (`:invalid_canonical_json` when the event contains floats or other values
  canonical JSON cannot represent). Never raises on malformed input.

  Unlike the signature — which is computed over the *redacted* event, and so
  says nothing about any field redaction strips — this covers the event
  verbatim, `content` included. It is therefore the only thing standing
  between a relaying server and rewriting the body of somebody else's
  `m.room.message` on its way through: the author's signature still verifies
  over the redacted form, because the body was never part of it.

  A failure is deliberately not phrased as "reject". Per the Server-Server
  API's checks-on-receipt list, an event that "passes signature checks" but
  fails hash checks "is redacted before being processed further" — a
  mismatch means the unsigned parts of the event can't be trusted, not
  necessarily that the whole event is forged. See
  `AxonFederation.EventVerification.verify/2`.

  The comparison is on the decoded digest, not the base64 text, so an event
  whose hash arrives in URL-safe base64 rather than the spec's unpadded
  standard base64 still verifies — the hash is 32 bytes, and which alphabet
  a peer spelled them in is not something to fail an event over.
  """
  @spec verify_content_hash(map()) ::
          :ok
          | {:error, :missing_content_hash | :content_hash_mismatch | :invalid_canonical_json}
  def verify_content_hash(event) when is_map(event) do
    with %{"hashes" => %{"sha256" => claimed}} when is_binary(claimed) <- event,
         {:ok, claimed_bytes} <- decode_unpadded_base64(claimed),
         {:ok, payload} <- CanonicalJSON.safe_encode_to_binary(content_hash_payload(event)) do
      if claimed_bytes == :crypto.hash(:sha256, payload),
        do: :ok,
        else: {:error, :content_hash_mismatch}
    else
      :error -> {:error, :content_hash_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :missing_content_hash}
    end
  end

  defp content_hash_payload(event), do: Map.drop(event, ["hashes" | @non_content_fields])

  defp decode_unpadded_base64(str) do
    case Base.decode64(str, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> Base.url_decode64(str, padding: false)
    end
  end

  @doc """
  Computes the reference hash used as the event_id in room versions 3+.

  Format: "$" <> unpadded_base64url(SHA256(canonical_json(redacted_event)))

  The hash is over the **redacted** event (reference implementation:
  `ReferenceSha256HashOfEvent` — "returns the SHA-256 hash of the redacted
  event content"). Hashing the unredacted event instead yields a different
  event ID than every other homeserver computes for the same event, which is
  self-consistent between two servers doing it and wrong against all others.

  `room_version` selects the redaction algorithm; it is required rather than
  defaulted, since a silently-wrong default is exactly the failure mode this
  replaces.
  """
  @spec reference_hash(map(), binary()) :: binary()
  def reference_hash(event, room_version) do
    hash =
      event
      |> Redaction.redact(room_version)
      |> Map.drop(["unsigned", "signatures", "event_id"])
      |> CanonicalJSON.encode_to_binary()
      |> sha256_b64url()

    "$" <> hash
  end

  @doc """
  Signs an event map with the given key.

  Returns the event with signatures[server_name][key_id] set.
  The key_id format is "ed25519:KEY_ID".
  """
  @spec sign_event(map(), binary(), binary(), binary(), binary()) :: map()
  def sign_event(event, server_name, key_id, private_key, room_version) do
    add_signature(event, signable_event(event, room_version), server_name, key_id, private_key)
  end

  @doc """
  Verifies a signature on an event.

  Returns :ok or {:error, reason}; never raises on malformed input.
  """
  @spec verify_signature(map(), binary(), binary(), binary(), binary()) ::
          :ok | {:error, :invalid_signature | :missing_signature}
  def verify_signature(event, server_name, key_id, public_key, room_version) when is_map(event) do
    verify_signed(event, signable_event(event, room_version), server_name, key_id, public_key)
  end

  def verify_signature(_event, _server_name, _key_id, _public_key, _room_version),
    do: {:error, :missing_signature}

  @doc """
  Signs a plain JSON object that is **not** a room event — the counterpart of
  `verify_json_signature/4`. No redaction step, for the same reason.
  """
  @spec sign_json(map(), binary(), binary(), binary()) :: map()
  def sign_json(object, signer, key_id, private_key) do
    add_signature(object, signable_json(object), signer, key_id, private_key)
  end

  @doc """
  Verifies a signature on a plain signed JSON object that is **not** a room
  event — a cross-signing key, or the `signed` block of a third-party invite.

  These are signed with the same JSON signing algorithm but have no room
  version and no redaction step: there is nothing to redact, and redacting
  would strip the very fields being attested. Kept separate from
  `verify_signature/5` so the two can't be confused at a call site.
  """
  @spec verify_json_signature(map(), binary(), binary(), binary()) ::
          :ok | {:error, :invalid_signature | :missing_signature}
  def verify_json_signature(object, signer, key_id, public_key) when is_map(object) do
    verify_signed(object, signable_json(object), signer, key_id, public_key)
  end

  def verify_json_signature(_object, _signer, _key_id, _public_key),
    do: {:error, :missing_signature}

  @doc "Signs raw bytes with an Ed25519 private key; returns the unpadded base64 signature."
  @spec sign_bytes(binary(), binary()) :: binary()
  def sign_bytes(payload, private_key) do
    :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
    |> Base.encode64(padding: false)
  end

  defp signable_event(event, room_version) do
    event
    |> Redaction.redact(room_version)
    |> Map.drop(@non_content_fields)
  end

  defp signable_json(object), do: Map.drop(object, ["signatures", "unsigned"])

  defp add_signature(object, signable, signer, key_id, private_key) do
    sig_b64 = signable |> CanonicalJSON.encode_to_binary() |> sign_bytes(private_key)

    signatures =
      case object["signatures"] do
        %{} = sigs -> sigs
        _ -> %{}
      end
      |> Map.update(signer, %{key_id => sig_b64}, &Map.put(&1, key_id, sig_b64))

    Map.put(object, "signatures", signatures)
  end

  defp verify_signed(object, signable, signer, key_id, public_key) do
    with {:ok, sig_bytes} <- fetch_signature(object, signer, key_id),
         {:ok, payload} <- CanonicalJSON.safe_encode_to_binary(signable),
         true <- ed25519_valid?(payload, sig_bytes, public_key) do
      :ok
    else
      {:error, :missing_signature} = error -> error
      _ -> {:error, :invalid_signature}
    end
  end

  defp fetch_signature(%{"signatures" => %{} = signatures}, signer, key_id) do
    case signatures do
      %{^signer => %{^key_id => sig_b64}} when is_binary(sig_b64) ->
        Base.decode64(sig_b64, padding: false)

      %{^signer => %{^key_id => _}} ->
        :error

      _ ->
        {:error, :missing_signature}
    end
  end

  defp fetch_signature(_object, _signer, _key_id), do: {:error, :missing_signature}

  defp ed25519_valid?(payload, sig_bytes, public_key) do
    :crypto.verify(:eddsa, :none, payload, sig_bytes, [public_key, :ed25519])
  rescue
    _ -> false
  end

  defp sha256_b64url(data) do
    data
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
