defmodule AxonCrypto.EventHash do
  @moduledoc """
  Matrix event hashing and signing.

  Spec: https://spec.matrix.org/latest/server-server-api/#calculating-the-content-hash-for-an-event
  """

  alias AxonCrypto.CanonicalJSON

  @doc """
  Computes the content hash of an event (for the `hashes.sha256` field).

  Remove unsigned, signatures, hashes from the event first, then SHA256 the canonical JSON.
  """
  @spec content_hash(map()) :: binary()
  def content_hash(event) do
    event
    |> Map.drop(["unsigned", "signatures", "hashes"])
    |> CanonicalJSON.encode_to_binary()
    |> sha256_b64url()
  end

  @doc """
  Computes the reference hash used as the event_id in room versions 3+.

  Format: "$" <> unpadded_base64url(SHA256(canonical_json_without_unsigned))
  """
  @spec reference_hash(map()) :: binary()
  def reference_hash(event) do
    hash =
      event
      |> Map.drop(["unsigned"])
      |> CanonicalJSON.encode_to_binary()
      |> sha256_b64url()

    "$" <> hash
  end

  @doc """
  Signs an event map with the given key.

  Returns the event with signatures[server_name][key_id] set.
  The key_id format is "ed25519:KEY_ID".
  """
  @spec sign_event(map(), binary(), binary(), binary()) :: map()
  def sign_event(event, server_name, key_id, private_key) do
    signable =
      event
      |> Map.drop(["unsigned", "signatures"])
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
  @spec verify_signature(map(), binary(), binary(), binary()) ::
          :ok | {:error, :invalid_signature | :missing_signature}
  def verify_signature(event, server_name, key_id, public_key) do
    with {:ok, sig_b64} <- get_signature(event, server_name, key_id),
         {:ok, sig_bytes} <- Base.decode64(sig_b64, padding: false) do
      signable =
        event
        |> Map.drop(["unsigned", "signatures"])
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
