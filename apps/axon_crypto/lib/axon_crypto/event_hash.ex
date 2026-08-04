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
  """
  @spec content_hash(map()) :: binary()
  def content_hash(event) do
    event
    |> Map.drop(["hashes" | @non_content_fields])
    |> CanonicalJSON.encode_to_binary()
    |> sha256_b64url()
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
    signable =
      event
      |> Redaction.redact(room_version)
      |> Map.drop(@non_content_fields)
      |> CanonicalJSON.encode_to_binary()

    sig_bytes = :crypto.sign(:eddsa, :none, signable, [private_key, :ed25519])
    sig_b64 = Base.encode64(sig_bytes, padding: false)

    existing_sigs = Map.get(event, "signatures", %{})
    server_sigs = Map.get(existing_sigs, server_name, %{})
    new_server_sigs = Map.put(server_sigs, key_id, sig_b64)
    new_sigs = Map.put(existing_sigs, server_name, new_server_sigs)

    Map.put(event, "signatures", new_sigs)
  end

  @doc """
  Verifies a signature on an event.

  Returns :ok or {:error, reason}.
  """
  @spec verify_signature(map(), binary(), binary(), binary(), binary()) ::
          :ok | {:error, :invalid_signature | :missing_signature}
  def verify_signature(event, server_name, key_id, public_key, room_version) do
    with {:ok, sig_b64} <- get_signature(event, server_name, key_id),
         {:ok, sig_bytes} <- Base.decode64(sig_b64, padding: false) do
      signable =
        event
        |> Redaction.redact(room_version)
        |> Map.drop(@non_content_fields)
        |> CanonicalJSON.encode_to_binary()

      if :crypto.verify(:eddsa, :none, signable, sig_bytes, [public_key, :ed25519]) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  @doc """
  Signs a plain JSON object that is **not** a room event — the counterpart of
  `verify_json_signature/4`. No redaction step, for the same reason.
  """
  @spec sign_json(map(), binary(), binary(), binary()) :: map()
  def sign_json(object, signer, key_id, private_key) do
    signable =
      object
      |> Map.drop(["signatures", "unsigned"])
      |> CanonicalJSON.encode_to_binary()

    sig_bytes = :crypto.sign(:eddsa, :none, signable, [private_key, :ed25519])
    sig_b64 = Base.encode64(sig_bytes, padding: false)

    signatures =
      object
      |> Map.get("signatures", %{})
      |> Map.update(signer, %{key_id => sig_b64}, &Map.put(&1, key_id, sig_b64))

    Map.put(object, "signatures", signatures)
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
  def verify_json_signature(object, signer, key_id, public_key) do
    with {:ok, sig_b64} <- get_signature(object, signer, key_id),
         {:ok, sig_bytes} <- Base.decode64(sig_b64, padding: false) do
      signable =
        object
        |> Map.drop(["signatures", "unsigned"])
        |> CanonicalJSON.encode_to_binary()

      if :crypto.verify(:eddsa, :none, signable, sig_bytes, [public_key, :ed25519]) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  defp get_signature(event, server_name, key_id) do
    case get_in(event, ["signatures", server_name, key_id]) do
      nil -> {:error, :missing_signature}
      sig -> {:ok, sig}
    end
  end

  defp sha256_b64url(data) do
    data
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
