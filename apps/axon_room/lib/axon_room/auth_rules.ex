defmodule AxonRoom.AuthRules do
  @moduledoc """
  Matrix event authorization rules for room versions 6-12.

  All functions are pure — no side effects, no DB calls.
  State is passed in as a map of {type, state_key} => event_map.

  Spec: https://spec.matrix.org/latest/rooms/v11/#authorization-rules
  """

  alias AxonRoom.RoomVersions

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Checks whether an event is authorized given the current room state.

  Returns `:ok` or `{:error, atom}`.
  """
  def check(event, current_state, room_version \\ "11"),
    do: check_type_specific(event, current_state, room_version)

  @doc """
  The room version recorded in `current_state`'s create event. Per spec a
  create event without `room_version` denotes room version "1".
  """
  def room_version(current_state) do
    case current_state[{"m.room.create", ""}] do
      %{"content" => %{"room_version" => v}} when is_binary(v) -> v
      _ -> "1"
    end
  end

  @doc "Whether `user_id` currently has at least invite power in this room (used to pick a restricted-join authoriser)."
  def can_invite?(user_id, current_state, version \\ "11"),
    do: has_power?(user_id, "invite", current_state, version)

  @doc """
  Whether `user_id` currently has enough power to send a state event of
  `event_type` in this room. Exposed for callers outside the event-send
  pipeline (e.g. directory alias management) that need the same authority
  `check/3` uses for state events — including room-v12 creator infinite
  power — rather than reimplementing power-level arithmetic themselves.
  """
  def can_send_state?(user_id, event_type, current_state, version \\ "11"),
    do: can_send?(user_id, event_type, true, current_state, version)

  @doc "Whether `user_id` is a syntactically valid user ID (`@localpart:server_name`)."
  def valid_user_id?(id) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      ["@" <> localpart, domain] -> localpart != "" and valid_server_name?(domain)
      _ -> false
    end
  end

  def valid_user_id?(_), do: false

  defp can_send?(user_id, event_type, state?, current_state, version) do
    pl = power_levels(current_state)
    effective_power(user_id, pl, current_state, version) >= required_level(pl, event_type, state?)
  end

  defp required_level(pl, event_type, state?) do
    {key, default} = if state?, do: {"state_default", 50}, else: {"events_default", 0}
    to_level(as_map(pl["events"])[event_type]) || level(pl, key, default)
  end

  # ---------------------------------------------------------------------------
  # m.room.create — must be the first event
  # ---------------------------------------------------------------------------

  defp check_type_specific(%{"type" => "m.room.create"} = event, current_state, version) do
    cond do
      # Room already has a create event
      Map.has_key?(current_state, {"m.room.create", ""}) ->
        {:error, :room_already_created}

      # prev_events must be empty
      event["prev_events"] != [] ->
        {:error, :create_event_has_prev_events}

      # Room v12 rule 1: additional_creators, if present, must be an array
      # of valid user IDs.
      version == "12" and not valid_additional_creators?(event) ->
        {:error, :invalid_additional_creators}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # All non-create events: sender must be joined
  # (except for join/invite/knock where sender is trying to enter)
  # ---------------------------------------------------------------------------

  defp check_type_specific(%{"type" => "m.room.member"} = event, current_state, version) do
    check_member_event(event, current_state, version)
  end

  defp check_type_specific(%{"type" => "m.room.power_levels"} = event, current_state, version) do
    with :ok <- check_sender_joined(event, current_state),
         :ok <- check_power_level_values_in_range(event),
         :ok <- check_power_level_for_state(event, current_state, version),
         :ok <- check_power_levels_content(event["content"], version),
         :ok <- check_creators_excluded_from_power_levels(event, current_state, version) do
      check_power_levels_changes(event, current_state, version)
    end
  end

  # Rule 7: m.room.third_party_invite is gated by invite power specifically,
  # not state_default like an arbitrary state event.
  defp check_type_specific(
         %{"type" => "m.room.third_party_invite"} = event,
         current_state,
         version
       ) do
    with :ok <- check_sender_joined(event, current_state) do
      if has_power?(event["sender"], "invite", current_state, version),
        do: :ok,
        else: {:error, :insufficient_power}
    end
  end

  defp check_type_specific(%{"state_key" => _} = event, current_state, version) do
    # Generic state event
    with :ok <- check_sender_joined(event, current_state) do
      check_power_level_for_state(event, current_state, version)
    end
  end

  defp check_type_specific(event, current_state, version) do
    # Message / non-state event
    with :ok <- check_sender_joined(event, current_state) do
      if can_send?(event["sender"], event["type"], false, current_state, version),
        do: :ok,
        else: {:error, :insufficient_power}
    end
  end

  defp valid_additional_creators?(event) do
    case get_in(event, ["content", "additional_creators"]) do
      nil -> true
      list when is_list(list) -> Enum.all?(list, &valid_user_id?/1)
      _ -> false
    end
  end

  # Server name grammar (hostname / IPv4 / bracketed IPv6, optional :port —
  # see the Matrix spec's server name grammar). Deliberately conservative:
  # this only needs to reject obviously-malformed domains (e.g. one
  # containing "$") in additional_creators/user-ID validation, not fully
  # implement DNS hostname rules.
  @server_name_re ~r/^(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*)(:[0-9]{1,5})?$/

  defp valid_server_name?(domain) when is_binary(domain) and domain != "",
    do: Regex.match?(@server_name_re, domain)

  defp valid_server_name?(_), do: false

  # ---------------------------------------------------------------------------
  # m.room.member detail
  # ---------------------------------------------------------------------------

  defp check_member_event(event, current_state, version) do
    sender = event["sender"]
    target = event["state_key"]
    membership = get_in(event, ["content", "membership"])

    case membership do
      "join" -> check_join(event, sender, target, current_state, version)
      "invite" -> check_invite(sender, target, current_state, version)
      "leave" -> check_leave(sender, target, current_state, version)
      "ban" -> check_ban(sender, target, current_state, version)
      "knock" -> check_knock(sender, target, current_state)
      _ -> {:error, :invalid_membership}
    end
  end

  defp check_join(event, sender, target, current_state, version) do
    cond do
      sender != target ->
        {:error, :cannot_join_for_another}

      initial_creator_join?(event, sender, current_state) ->
        :ok

      true ->
        sender_membership = current_membership(sender, current_state)
        join_rule = join_rule(current_state)

        cond do
          sender_membership == "ban" ->
            {:error, :banned}

          sender_membership == "join" ->
            :ok

          valid_third_party_invite?(event, sender, current_state) ->
            :ok

          join_rule in ["public", "open"] ->
            :ok

          join_rule == "invite" ->
            if sender_membership == "invite", do: :ok, else: {:error, :not_invited}

          join_rule in ["restricted", "knock_restricted"] ->
            check_restricted_join(event, sender_membership, current_state, version)

          join_rule == "knock" ->
            # Spec rule 4.3.4: "If the join_rule is invite or knock then
            # allow if membership state is invite or join." A prior
            # "knock" state is *not* sufficient on its own — knocking only
            # grants the right to be seen/invited/rejected, never a
            # self-service join. (The `sender_membership == "join"` case
            # above already short-circuits rejoin, so this really only
            # matters for the "invite" branch here.)
            if sender_membership == "invite", do: :ok, else: {:error, :not_invited}

          true ->
            {:error, :not_invited}
        end
    end
  end

  # Rule 4.3.1: the creator's own first join, whose only prev_event is the
  # create event. This is the only way a creator joins without an invite.
  defp initial_creator_join?(event, sender, current_state) do
    case current_state[{"m.room.create", ""}] do
      %{"sender" => ^sender, "event_id" => create_id} when is_binary(create_id) ->
        prev_event_ids(event["prev_events"]) == [create_id]

      _ ->
        false
    end
  end

  # Room versions 1/2 encode prev_events as [event_id, hashes] pairs.
  defp prev_event_ids(prev_events) when is_list(prev_events),
    do:
      Enum.map(prev_events, fn
        [id | _] -> id
        id -> id
      end)

  defp prev_event_ids(_), do: []

  # Third-party invites: a join whose content.third_party_invite.signed
  # names this sender, references a token matching a live
  # m.room.third_party_invite state event in this room, and carries a
  # signature verifiable against one of that event's public keys is
  # authorized regardless of the room's normal join_rule — the 3pid invite
  # itself is the authorization, exactly like a direct m.room.member invite
  # would be.
  #
  # The public keys checked against come entirely from the room's own
  # m.room.third_party_invite state content (third_party_invite_public_keys/1)
  # — whichever server actually produced them (axon's own key for a
  # legacy self-signed invite, or a real identity server's long-term/
  # ephemeral key for a delegated one, see
  # AxonWeb.RoomController.third_party_invite_content/1) verifies exactly
  # the same way; nothing here assumes it's always axon's own key.
  defp valid_third_party_invite?(event, sender, current_state) do
    with %{"signed" => %{"mxid" => mxid, "token" => token} = signed}
         when is_binary(token) <- get_in(event, ["content", "third_party_invite"]),
         true <- mxid == sender,
         %{"content" => invite_content} <- current_state[{"m.room.third_party_invite", token}],
         true <- third_party_signature_valid?(signed, invite_content) do
      true
    else
      _ -> false
    end
  end

  # Verifies `signed` exactly as `AxonCrypto.EventHash.sign_json/4` would
  # have produced it: signed over *all* of its own fields other than
  # "signatures"/"unsigned" (delegated to verify_json_signature/4 itself,
  # not reconstructed here). A real identity server's sign-ed25519 (e.g.
  # Sydent's) signs `{mxid, sender, token}` — an extra "sender" field
  # beyond the two spec names for the payload — so hardcoding a
  # `Map.take(signed, ["mxid", "token"])` allowlist here would silently
  # fail every real-identity-server-produced signature; matching whatever
  # fields are actually present is what makes this identity-server-agnostic.
  defp third_party_signature_valid?(signed, invite_content) do
    sig_map = signed["signatures"] || %{}
    keys = third_party_invite_public_keys(invite_content)

    Enum.any?(sig_map, fn {issuer, key_sigs} ->
      Enum.any?(Map.keys(key_sigs), fn key_id ->
        Enum.any?(keys, fn pubkey_b64 ->
          case Base.decode64(pubkey_b64, padding: false) do
            {:ok, pubkey_bytes} ->
              AxonCrypto.EventHash.verify_json_signature(signed, issuer, key_id, pubkey_bytes) ==
                :ok

            :error ->
              false
          end
        end)
      end)
    end)
  end

  defp third_party_invite_public_keys(invite_content) do
    from_list = (invite_content["public_keys"] || []) |> Enum.map(& &1["public_key"])
    [invite_content["public_key"] | from_list] |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  # MSC3083 restricted joins. A server that isn't itself resident in one of
  # the room's `allow`-listed rooms can't know the joiner's membership there,
  # so the actual "is this user allow-listed" check happens out-of-band
  # (AxonRoom.RestrictedJoin, which has DB access) before the join event is
  # ever built. What AuthRules verifies here — purely from this room's own
  # state — is the vouching mechanism: the event must name a
  # `join_authorised_via_users_server` user who is currently joined to *this*
  # room with at least invite power. Trusting that stamp is safe because the
  # event is signed by the authorising user's own homeserver.
  defp check_restricted_join(event, sender_membership, current_state, version) do
    authoriser = get_in(event, ["content", "join_authorised_via_users_server"])

    cond do
      sender_membership == "invite" ->
        :ok

      is_binary(authoriser) and current_membership(authoriser, current_state) == "join" and
          has_power?(authoriser, "invite", current_state, version) ->
        :ok

      true ->
        {:error, :not_invited}
    end
  end

  defp check_invite(sender, target, current_state, version) do
    sender_membership = current_membership(sender, current_state)
    target_membership = current_membership(target, current_state)

    cond do
      sender_membership != "join" ->
        {:error, :not_joined}

      target_membership == "ban" ->
        {:error, :target_banned}

      target_membership == "join" ->
        {:error, :already_joined}

      not has_power?(sender, "invite", current_state, version) ->
        {:error, :insufficient_power}

      true ->
        :ok
    end
  end

  defp check_leave(sender, target, current_state, version) do
    sender_membership = current_membership(sender, current_state)
    target_membership = current_membership(target, current_state)

    if sender == target do
      # Self-leave: OK if joined, invited, or knocking (spec rule 4.5.1 —
      # rescinding a knock is a plain self-leave from the "knock" state,
      # same as declining an invite).
      if sender_membership in ["join", "invite", "knock"],
        do: :ok,
        else: {:error, :not_joined}
    else
      cond do
        sender_membership != "join" ->
          {:error, :not_joined}

        # Unban ("leave" targeting a banned user) is gated by ban power, not
        # kick power — this must be checked before the generic
        # not-in-room rejection below, or a banned target (whose membership
        # is legitimately "ban", not "join"/"invite") can never be unbanned
        # by anyone, ever.
        target_membership == "ban" ->
          if has_power?(sender, "ban", current_state, version),
            do: :ok,
            else: {:error, :insufficient_power}

        # A room member rejecting someone else's knock is also a plain
        # leave event, gated by ordinary kick power below — "knock" must be
        # accepted here as a valid target state alongside "join"/"invite".
        target_membership not in ["join", "invite", "knock"] ->
          {:error, :target_not_in_room}

        not has_power_over?(sender, target, "kick", current_state, version) ->
          {:error, :insufficient_power}

        true ->
          :ok
      end
    end
  end

  defp check_ban(sender, target, current_state, version) do
    sender_membership = current_membership(sender, current_state)

    cond do
      sender_membership != "join" ->
        {:error, :not_joined}

      not has_power_over?(sender, target, "ban", current_state, version) ->
        {:error, :insufficient_power}

      true ->
        :ok
    end
  end

  defp check_knock(sender, target, current_state) do
    if sender != target do
      {:error, :cannot_knock_for_another}
    else
      sender_membership = current_membership(sender, current_state)
      join_rule = join_rule(current_state)

      cond do
        join_rule not in ["knock", "knock_restricted"] ->
          {:error, :knocking_not_allowed}

        sender_membership in ["join", "ban", "invite"] ->
          {:error, :already_in_room}

        true ->
          :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Power level checks
  # ---------------------------------------------------------------------------

  defp check_sender_joined(event, current_state) do
    sender = event["sender"]

    if current_membership(sender, current_state) == "join",
      do: :ok,
      else: {:error, :not_joined}
  end

  defp check_power_level_for_state(event, current_state, version) do
    if can_send_state?(event["sender"], event["type"], current_state, version),
      do: :ok,
      else: {:error, :insufficient_power}
  end

  # Every m.room.power_levels numeric value (users.*, ban/kick/redact/invite,
  # events.*, events_default/state_default/users_default) must stay within
  # the canonical-JSON-safe integer range, same as any other number in a
  # signed Matrix event — a value outside it can't round-trip through
  # canonical JSON (used for content hashing/signing) consistently across
  # implementations. This also indirectly protects the room-v12 creator
  # comparisons in `effective_power/4`: a legitimately-set power level can
  # never be JSON-encoded any higher than this, so @infinite_power only
  # needs to out-rank this ceiling, not an unbounded client-supplied number.
  @max_canonical_json_int 9_007_199_254_740_991

  defp check_power_level_values_in_range(event) do
    content = event["content"] || %{}

    if content |> collect_integers() |> Enum.all?(&(abs(&1) <= @max_canonical_json_int)),
      do: :ok,
      else: {:error, :power_level_value_out_of_range}
  end

  defp collect_integers(value) when is_integer(value), do: [value]

  defp collect_integers(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&collect_integers/1)

  defp collect_integers(value) when is_list(value),
    do: Enum.flat_map(value, &collect_integers/1)

  defp collect_integers(_value), do: []

  @pl_levels ~w(users_default events_default state_default ban redact kick invite)

  # Rules 10.1-10.3: top-level levels must be integers; events,
  # notifications and users must be objects of integers, users keyed by
  # user ID. Room versions before 10 also accept integer-valued strings.
  defp check_power_levels_content(content, version) when is_map(content) do
    valid? =
      Enum.all?(@pl_levels, &(not Map.has_key?(content, &1) or level?(content[&1], version))) and
        Enum.all?(
          ["events", "notifications", "users"],
          &(not Map.has_key?(content, &1) or level_map?(content[&1], version))
        ) and
        Enum.all?(Map.keys(as_map(content["users"])), &power_levels_user_key?/1)

    if valid?, do: :ok, else: {:error, :invalid_power_levels}
  end

  defp check_power_levels_content(_content, _version), do: {:error, :invalid_power_levels}

  defp level?(value, version) do
    if RoomVersions.at_least?(version, 10), do: is_integer(value), else: to_level(value) != nil
  end

  defp level_map?(map, version) when is_map(map),
    do: Enum.all?(Map.values(map), &level?(&1, version))

  defp level_map?(_map, _version), do: false

  defp power_levels_user_key?("@" <> _ = user_id),
    do: AxonCore.MatrixId.server_name(user_id) != nil

  defp power_levels_user_key?(_), do: false

  # Rules 10.5-10.10: with a previous power_levels event, every changed
  # level must be within the sender's own power, both before and after the
  # change; another user's entry may only be changed while it is below the
  # sender's power.
  defp check_power_levels_changes(event, current_state, version) do
    case current_state[{"m.room.power_levels", ""}] do
      %{"content" => old} when is_map(old) ->
        new = event["content"]
        sender = event["sender"]

        sender_level =
          effective_power(sender, power_levels(current_state), current_state, version)

        sections =
          if RoomVersions.at_least?(version, 6), do: ["events", "notifications"], else: ["events"]

        user_changes = changed_levels(as_map(old["users"]), as_map(new["users"]))

        changes =
          changed_levels(old, new, @pl_levels) ++
            Enum.flat_map(sections, &changed_levels(as_map(old[&1]), as_map(new[&1]))) ++
            user_changes

        allowed? =
          Enum.all?(changes, fn {_key, old_level, new_level} ->
            within?(old_level, sender_level) and within?(new_level, sender_level)
          end) and
            Enum.all?(user_changes, fn {user_id, old_level, _new_level} ->
              user_id == sender or old_level == nil or old_level < sender_level
            end)

        if allowed?, do: :ok, else: {:error, :insufficient_power}

      _ ->
        :ok
    end
  end

  defp changed_levels(old, new, keys \\ nil) do
    (keys || Enum.uniq(Map.keys(old) ++ Map.keys(new)))
    |> Enum.map(&{&1, to_level(old[&1]), to_level(new[&1])})
    |> Enum.reject(fn {_key, old_level, new_level} -> old_level == new_level end)
  end

  defp within?(nil, _sender_level), do: true
  defp within?(level, sender_level), do: level <= sender_level

  # Rule 10.4 (room v12): the users map in a new m.room.power_levels event
  # must not contain the sender of m.room.create or any of the
  # additional_creators — they're never listed there (implicit infinite
  # power instead), so an entry for one of them can only be an attempt to
  # (nonsensically, since it's ignored either way) demote a creator.
  defp check_creators_excluded_from_power_levels(_event, _current_state, version)
       when version != "12",
       do: :ok

  defp check_creators_excluded_from_power_levels(event, current_state, "12") do
    users = get_in(event, ["content", "users"]) || %{}
    creators = creator_ids(current_state, "12")

    if Enum.any?(Map.keys(users), &MapSet.member?(creators, &1)),
      do: {:error, :power_levels_may_not_list_creators},
      else: :ok
  end

  # ---------------------------------------------------------------------------
  # State helpers
  # ---------------------------------------------------------------------------

  # Room v12 (MSC4297/MSC4289): "creators" are the create event's sender
  # plus any additional_creators from its content — they hold implicit,
  # infinite power and are never listed in power_levels.users. Earlier
  # versions have a single creator, and always used content.creator (kept
  # here as a defensive fallback for a create event that omits it, though
  # this codebase always sets it); the create event's sender is
  # authoritative in every room version, since auth rule 1 has always
  # required it.
  defp creator_ids(current_state, version) do
    case current_state[{"m.room.create", ""}] do
      nil ->
        MapSet.new()

      event ->
        primary = event["sender"] || get_in(event, ["content", "creator"])

        additional =
          if version == "12",
            do: get_in(event, ["content", "additional_creators"]) || [],
            else: []

        MapSet.new([primary | additional]) |> MapSet.delete(nil)
    end
  end

  defp room_creator?(user_id, current_state, version) do
    MapSet.member?(creator_ids(current_state, version), user_id)
  end

  defp current_membership(user_id, current_state) do
    case current_state[{"m.room.member", user_id}] do
      nil -> nil
      event -> get_in(event, ["content", "membership"])
    end
  end

  defp join_rule(current_state) do
    case current_state[{"m.room.join_rules", ""}] do
      nil -> "invite"
      event -> get_in(event, ["content", "join_rule"]) || "invite"
    end
  end

  defp power_levels(current_state) do
    case current_state[{"m.room.power_levels", ""}] do
      %{"content" => content} when is_map(content) -> content
      _ -> %{}
    end
  end

  defp as_map(value) when is_map(value), do: value
  defp as_map(_value), do: %{}

  # A malformed (or pre-v10 string-valued) level never crashes a
  # comparison: integer-valued strings are parsed, anything else is absent.
  defp to_level(value) when is_integer(value), do: value

  defp to_level(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_level(_value), do: nil

  defp level(pl, key, default), do: to_level(pl[key]) || default

  # Room v12: creators have unconditional, infinite power — never listed in
  # power_levels.users, can never be outranked or demoted (rule: "cannot be
  # specified in the m.room.power_levels event", "infinitely high power
  # level"). Earlier versions: when no power_levels event exists yet, the
  # room creator has implicit level 100 (an empty PL event {} still counts
  # as existing → no implicit 100 in that case).
  #
  # This must be strictly greater than the largest power level a client can
  # actually set: power_levels.users values are JSON numbers, and Matrix
  # requires them to stay within the canonical-JSON-safe integer range
  # (±(2^53 - 1), see EventHash/canonical JSON validation) — 9007199254740991
  # at the top end. A creator's "infinite" power must out-rank even that, or
  # a non-creator admin promoted to the JSON-max power level would
  # incorrectly out-rank (and be able to kick/ban) the room's own creator,
  # while the creator would incorrectly fail to out-rank *them* — both
  # directions of this bug are exercised by Complement's
  # TestMSC4289PrivilegedRoomCreators subtests ("creator can kick admin at
  # JSON max value" and "admin with >PL100 cannot kick creator").
  @infinite_power 1_000_000_000_000_000_000

  defp effective_power(user_id, pl, current_state, version) do
    cond do
      version == "12" and room_creator?(user_id, current_state, version) ->
        @infinite_power

      version != "12" and not Map.has_key?(current_state, {"m.room.power_levels", ""}) and
          room_creator?(user_id, current_state, version) ->
        100

      true ->
        sender_power(user_id, pl)
    end
  end

  defp sender_power(user_id, pl),
    do: to_level(as_map(pl["users"])[user_id]) || level(pl, "users_default", 0)

  defp has_power?(user_id, action, current_state, version) do
    pl = power_levels(current_state)

    effective_power(user_id, pl, current_state, version) >=
      level(pl, action, default_pl_for(action))
  end

  defp has_power_over?(sender, target, action, current_state, version) do
    pl = power_levels(current_state)
    sender_pl = effective_power(sender, pl, current_state, version)
    target_pl = effective_power(target, pl, current_state, version)
    sender_pl >= level(pl, action, default_pl_for(action)) && sender_pl > target_pl
  end

  defp default_pl_for("invite"), do: 0
  defp default_pl_for(_), do: 50
end
