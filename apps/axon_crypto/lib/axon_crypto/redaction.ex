defmodule AxonCrypto.Redaction do
  @moduledoc """
  The spec's event redaction algorithm.

  This is not only what `m.room.redaction` applies — it is a prerequisite for
  *every* signature and event ID in the protocol. Per the Server-Server API,
  an event is redacted **before** it is signed, and its reference hash (which
  is the event ID for room versions 3+) is likewise computed over the redacted
  form. The reference implementation says why, at
  `gomatrixserverlib/eventcrypto.go`:

      // Redact the event before signing so signature that will remain valid
      // even if the event is redacted.

  That is the whole design: redaction strips content a server may not want to
  keep, and the signature must still verify afterwards, which is only possible
  if it never covered the stripped fields to begin with.

  Signing or hashing the *unredacted* event is self-consistent — two servers
  that both do it agree with each other — so it can pass every
  same-implementation test while making federation with any spec-compliant
  homeserver impossible in both directions.

  The version cutoffs below are transcribed from `gomatrixserverlib`'s
  `eventversion.go`/`redactevent.go` rather than inferred, because they are
  easy to get subtly wrong and a wrong cutoff is invisible until a real peer
  rejects a signature. Two independent axes:

  **Top-level keys** — `origin`, `prev_state` and `membership` survive for
  room versions 1–10 and are dropped from v11 (`unredactableEventFieldsV1`
  vs `...V2`; only `redactEventJSONV5`, used by v11+, takes the latter).

  **Content keys** — five variants, keyed by version:

  | versions | `m.room.member`            | `m.room.create` | `join_rules`      | `power_levels` extra | other                  |
  |----------|----------------------------|-----------------|-------------------|----------------------|------------------------|
  | 1–5      | membership                 | creator         | join_rule         | —                    | `m.room.aliases`       |
  | 6–7      | membership                 | creator         | join_rule         | —                    | —                      |
  | 8        | membership                 | creator         | join_rule, allow  | —                    | —                      |
  | 9–10     | + join_authorised_via_...  | creator         | join_rule, allow  | —                    | —                      |
  | 11+      | + join_authorised_via_...  | *all fields*    | join_rule, allow  | invite               | `m.room.redaction`     |
  """

  @v1_top_level ~w(
    event_id type room_id sender state_key content hashes signatures
    depth prev_events prev_state auth_events origin origin_server_ts membership
  )

  @v2_top_level ~w(
    event_id type room_id sender state_key content hashes signatures
    depth prev_events auth_events origin_server_ts
  )

  @base_power_levels ~w(ban events events_default kick redact state_default users users_default)

  @doc """
  Redacts `event` according to `room_version`'s redaction algorithm.

  Both arguments are wire-format maps with string keys.
  """
  def redact(event, room_version) when is_map(event) do
    v = to_string(room_version)

    allowed_top = if v in ~w(1 2 3 4 5 6 7 8 9 10), do: @v1_top_level, else: @v2_top_level

    redacted = Map.take(event, allowed_top)

    # `content` is always present in the redacted form, even when the original
    # had none — the reference struct marshals it without `omitempty`, so
    # omitting the key here would produce different canonical JSON (and so a
    # different signature and event ID) for an event with no content.
    content = if is_map(event["content"]), do: event["content"], else: %{}
    Map.put(redacted, "content", redact_content(event["type"], content, v))
  end

  defp redact_content("m.room.member", content, v) do
    keep =
      if v in ~w(1 2 3 4 5 6 7 8),
        do: ["membership"],
        else: ["membership", "join_authorised_via_users_server"]

    Map.take(content, keep)
  end

  # From v11 the create event keeps its entire content (MSC2176).
  defp redact_content("m.room.create", content, v) do
    if v in ~w(1 2 3 4 5 6 7 8 9 10), do: Map.take(content, ["creator"]), else: content
  end

  # `allow` (restricted rooms) is protected from v8 onwards.
  defp redact_content("m.room.join_rules", content, v) do
    keep = if v in ~w(1 2 3 4 5 6 7), do: ["join_rule"], else: ["join_rule", "allow"]
    Map.take(content, keep)
  end

  defp redact_content("m.room.power_levels", content, v) do
    keep = if v in ~w(1 2 3 4 5 6 7 8 9 10), do: @base_power_levels, else: @base_power_levels ++ ["invite"]
    Map.take(content, keep)
  end

  defp redact_content("m.room.history_visibility", content, _v),
    do: Map.take(content, ["history_visibility"])

  # m.room.aliases lost its special meaning in v6.
  defp redact_content("m.room.aliases", content, v) do
    if v in ~w(1 2 3 4 5), do: Map.take(content, ["aliases"]), else: %{}
  end

  # `redacts` moved into content in v11 (MSC2174); before that it is a
  # top-level key and content keeps nothing.
  defp redact_content("m.room.redaction", content, v) do
    if v in ~w(1 2 3 4 5 6 7 8 9 10), do: %{}, else: Map.take(content, ["redacts"])
  end

  defp redact_content(_type, _content, _v), do: %{}
end
