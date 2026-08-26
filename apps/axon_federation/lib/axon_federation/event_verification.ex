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
  signature — that's the content hash's job. `verify/2` below does both, in
  the order and with the failure modes the spec prescribes; `verify_signature/2`
  on its own attests authorship, not body integrity.

  ## Signature failure drops, hash failure redacts

  The Server-Server API's "checks performed on receipt of a PDU" is an
  ordered list, and the two checks here fail *differently*:

      2. Passes signature checks, otherwise it is dropped.
      3. Passes hash checks, otherwise it is redacted before being
         processed further.

  That asymmetry is the whole point of `verify/2`. A bad signature means
  nobody vouched for the event and there is nothing to salvage. A bad
  content hash means only that the parts of the event redaction would strip
  — chiefly `content` — disagree with what the author signed over; the
  author's attestation of the redacted form is still perfectly good. That
  is exactly the shape of a *relaying* server rewriting the body of a
  message it forwards, and the spec's answer is to keep the event and
  discard the untrusted content, not to refuse the event and lose the fact
  that it happened at all.
  """

  alias AxonCrypto.{EventHash, Redaction}
  alias AxonFederation.KeyCache

  require Logger

  @doc """
  The full inbound-PDU check: signature, then content hash.

  Returns `{:ok, event}` — where `event` is the event as received when its
  content hash checked out, and its **redacted** form when it did not — or
  `{:error, reason}` when the signature check failed, in which case there is
  nothing to apply.

  Callers must apply the event this returns rather than the one they passed
  in; that substitution *is* the fix. `event_id` is carried across the
  redaction because it is not a real event field for room versions 3+ (it's
  the reference hash, computed over the redacted form and therefore
  identical either way) but every local caller downstream — RoomProcess,
  EventStore — needs it present on the map.
  """
  @spec verify(map(), binary()) :: {:ok, map()} | {:error, atom()}
  def verify(event, room_version) do
    with :ok <- verify_signature(event, room_version) do
      {:ok, content_hash_checked(event, room_version)}
    end
  end

  @doc """
  `event` if its content hash is correct, otherwise its redacted form.

  Split out from `verify/2` for the caller that has already established
  authorship some other way and only needs step 3.
  """
  @spec content_hash_checked(map(), binary()) :: map()
  def content_hash_checked(event, room_version) do
    case EventHash.verify_content_hash(event) do
      :ok ->
        event

      {:error, reason} ->
        Logger.warning(
          "Content hash #{reason} on #{event["type"]} #{event["event_id"]} from " <>
            "#{event["sender"]}; applying its redacted form"
        )

        redact_preserving_event_id(event, room_version)
    end
  end

  defp redact_preserving_event_id(event, room_version) do
    redacted = Redaction.redact(event, room_version)

    case Map.fetch(event, "event_id") do
      {:ok, event_id} -> Map.put(redacted, "event_id", event_id)
      :error -> redacted
    end
  end

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
