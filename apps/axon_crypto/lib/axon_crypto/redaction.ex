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
  that both do it agree with each other — so it can pass every same-implementation
  test while making federation with any spec-compliant homeserver impossible in
  both directions: their signatures fail to verify here, and every event ID
  computed here disagrees with theirs for the same event.

  The keep-lists below are the union across the room versions axon supports
  (2–12), with the version-specific differences called out inline.
  """

  # Top-level keys that survive redaction. `origin`, `membership` and
  # `prev_state` were dropped from this list in room version 11 (MSC2176 /
  # MSC3989); keeping them for older rooms is what those versions specify.
  @top_level_keys ~w(
    event_id type room_id sender state_key content hashes signatures
    depth prev_events auth_events origin_server_ts
  )

  @pre_v11_extra_top_level ~w(origin membership prev_state)

  @doc """
  Redacts `event` according to `room_version`'s redaction algorithm.

  Both arguments are wire-format maps with string keys.
  """
  def redact(event, room_version) when is_map(event) do
    allowed_top =
      if pre_v11?(room_version),
        do: @top_level_keys ++ @pre_v11_extra_top_level,
        else: @top_level_keys

    redacted = Map.take(event, allowed_top)

    case Map.fetch(event, "content") do
      {:ok, content} when is_map(content) ->
        Map.put(redacted, "content", redact_content(event["type"], content, room_version))

      _ ->
        redacted
    end
  end

  defp pre_v11?(version), do: to_string(version) in ~w(1 2 3 4 5 6 7 8 9 10)

  # m.room.create keeps its whole content from room version 11 onwards
  # (MSC2176); before that only `creator` survived.
  defp redact_content("m.room.create", content, room_version) do
    if pre_v11?(room_version), do: Map.take(content, ["creator"]), else: content
  end

  defp redact_content("m.room.member", content, _room_version) do
    kept = Map.take(content, ["membership", "join_authorised_via_users_server"])

    # third_party_invite survives, but only its `signed` member.
    case content do
      %{"third_party_invite" => %{"signed" => signed}} ->
        Map.put(kept, "third_party_invite", %{"signed" => signed})

      _ ->
        kept
    end
  end

  defp redact_content("m.room.join_rules", content, _),
    do: Map.take(content, ["join_rule", "allow"])

  defp redact_content("m.room.power_levels", content, _) do
    Map.take(content, ~w(
      ban events events_default invite kick redact state_default users users_default
    ))
  end

  defp redact_content("m.room.history_visibility", content, _),
    do: Map.take(content, ["history_visibility"])

  # `redacts` moved into content in room version 11 (MSC2174); in older
  # versions it is a top-level key and content keeps nothing.
  defp redact_content("m.room.redaction", content, room_version) do
    if pre_v11?(room_version), do: %{}, else: Map.take(content, ["redacts"])
  end

  defp redact_content("m.room.aliases", content, room_version) do
    # Only room versions before 6 kept aliases; the event type itself was
    # removed from the protocol later.
    if to_string(room_version) in ~w(1 2 3 4 5),
      do: Map.take(content, ["aliases"]),
      else: %{}
  end

  defp redact_content("m.room.server_acl", content, room_version) do
    # MSC2870: server ACLs keep their rules from room version 9 onwards, so a
    # redaction can't silently disable a room's ACL.
    if to_string(room_version) in ~w(1 2 3 4 5 6 7 8),
      do: %{},
      else: Map.take(content, ["allow", "deny", "allow_ip_literals"])
  end

  defp redact_content(_type, _content, _room_version), do: %{}
end
