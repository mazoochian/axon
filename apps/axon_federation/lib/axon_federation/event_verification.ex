defmodule AxonFederation.EventVerification do
  @moduledoc """
  Verifies an inbound PDU's signature against the key of the server its
  `sender` belongs to. Shared between `AxonWeb.FederationController` (PDUs
  arriving over `/send`) and `AxonFederation.Backfill` (PDUs fetched
  proactively via `get_missing_events`/`backfill`) — both need the exact
  same check, since fetched events are not pre-vetted the way a
  `send_join` state snapshot is.

  ## Why the sender's domain and not `origin`

  This used to pick the key-holding server out of the event's own `origin`
  field, falling back to the sender's domain only when `origin` was absent.
  Every federating server's signing key is public and fetchable, so that
  made cross-server impersonation trivial: an attacker running `evil.test`
  crafts an event with `sender = @victim:good.com`, sets `origin` to
  `evil.test`, and signs it with `evil.test`'s own key. Verification looked
  up `evil.test`'s key — the one that actually signed — and the event was
  accepted as authentic, though `good.com` never touched it. `origin` is
  attacker-supplied wire data on an unauthenticated-by-content payload; it
  cannot be allowed to choose which key attests to the event.

  The spec's rule is that a PDU is signed by the server of the user in
  `sender`, so that is what is checked, and `origin` is now ignored entirely
  for key selection. It is not *rejected* on mismatch: `origin` is a
  deprecated field that room versions 1-10 still carry through redaction,
  and hard-failing on it would reject legitimate traffic from servers that
  populate it in ways this server has no reason to police.

  Note that a redaction-stripped `content` is still not covered by this
  signature (see the audit's M1) — that's the content hash's job, checked
  elsewhere or not at all; this function attests authorship, not body
  integrity.
  """

  alias AxonCrypto.EventHash
  alias AxonFederation.KeyCache

  @doc "Verifies `event`'s signature from its sender's server. Returns :ok or {:error, reason}."
  def verify_signature(event, room_version) do
    sender_server = event["sender"] |> to_string() |> AxonCore.MatrixId.server_name()

    if is_nil(sender_server) do
      {:error, :missing_sender}
    else
      verify_signature_from(event, sender_server, room_version)
    end
  end

  @doc """
  Verifies that `server` signed `event`. `verify_signature/2` is this with
  `server` fixed to the sender's domain; a caller needing an *additional*
  signature from some other server (a restricted-room join's authorising
  server, say) can ask for that one by name — but never instead of the
  sender's.
  """
  def verify_signature_from(event, server, room_version) when is_binary(server) do
    key_id = get_in(event, ["signatures", server]) |> maybe_first_key()

    if is_nil(key_id) do
      {:error, :missing_signature}
    else
      pub_key = KeyCache.get_key(server, key_id)

      if is_nil(pub_key) do
        {:error, :key_not_found}
      else
        case EventHash.verify_signature(event, server, key_id, pub_key, room_version) do
          :ok ->
            :ok

          {:error, _} -> {:error, :bad_signature}
        end
      end
    end
  end

  defp maybe_first_key(nil), do: nil

  defp maybe_first_key(map) when is_map(map) do
    case Map.keys(map) do
      [] -> nil
      [key | _] -> key
    end
  end
end
