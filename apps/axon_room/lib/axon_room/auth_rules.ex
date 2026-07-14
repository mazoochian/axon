defmodule AxonRoom.AuthRules do
  @moduledoc """
  Matrix event authorization rules for room versions 6-12.

  All functions are pure — no side effects, no DB calls.
  State is passed in as a map of {type, state_key} => event_map.

  Spec: https://spec.matrix.org/latest/rooms/v11/#authorization-rules
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Checks whether an event is authorized given the current room state.

  Returns `:ok` or `{:error, atom}`.
  """
  def check(event, current_state, room_version \\ "11") do
    with :ok <- check_type_specific(event, current_state, room_version) do
      :ok
    end
  end

  @doc "Whether `user_id` currently has at least invite power in this room (used to pick a restricted-join authoriser)."
  def can_invite?(user_id, current_state, version \\ "11"),
    do: has_power?(user_id, "invite", current_state, version)

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
         :ok <- check_power_level_for_state(event, current_state, version),
         :ok <- check_creators_excluded_from_power_levels(event, current_state, version) do
      :ok
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
    with :ok <- check_sender_joined(event, current_state),
         :ok <- check_power_level_for_state(event, current_state, version) do
      :ok
    end
  end

  defp check_type_specific(event, current_state, version) do
    # Message / non-state event
    with :ok <- check_sender_joined(event, current_state),
         :ok <- check_power_level_for_send(event, current_state, version) do
      :ok
    end
  end

  defp valid_additional_creators?(event) do
    case get_in(event, ["content", "additional_creators"]) do
      nil -> true
      list when is_list(list) -> Enum.all?(list, &valid_user_id?/1)
      _ -> false
    end
  end

  defp valid_user_id?(id) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      ["@" <> localpart, domain] -> localpart != "" and domain != ""
      _ -> false
    end
  end

  defp valid_user_id?(_), do: false

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
            # Allow if invited OR if a room creator (initial join before join_rules event exists)
            if sender_membership == "invite" or room_creator?(sender, current_state, version),
              do: :ok,
              else: {:error, :not_invited}

          join_rule in ["restricted", "knock_restricted"] ->
            check_restricted_join(event, sender, sender_membership, current_state, version)

          join_rule == "knock" ->
            if sender_membership in ["invite", "knock"], do: :ok, else: {:error, :not_invited}

          true ->
            {:error, :not_invited}
        end
    end
  end

  # Third-party invites: a join whose content.third_party_invite.signed
  # names this sender, references a token matching a live
  # m.room.third_party_invite state event in this room, and carries a
  # signature verifiable against one of that event's public keys is
  # authorized regardless of the room's normal join_rule — the 3pid invite
  # itself is the authorization, exactly like a direct m.room.member invite
  # would be.
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

  defp third_party_signature_valid?(signed, invite_content) do
    payload = Map.take(signed, ["mxid", "token"])
    sig_map = signed["signatures"] || %{}
    to_verify = Map.put(payload, "signatures", sig_map)
    keys = third_party_invite_public_keys(invite_content)

    Enum.any?(sig_map, fn {issuer, key_sigs} ->
      Enum.any?(Map.keys(key_sigs), fn key_id ->
        Enum.any?(keys, fn pubkey_b64 ->
          case Base.decode64(pubkey_b64, padding: false) do
            {:ok, pubkey_bytes} ->
              AxonCrypto.EventHash.verify_signature(to_verify, issuer, key_id, pubkey_bytes) ==
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
  defp check_restricted_join(event, sender, sender_membership, current_state, version) do
    authoriser = get_in(event, ["content", "join_authorised_via_users_server"])

    cond do
      sender_membership == "invite" or room_creator?(sender, current_state, version) ->
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
      # Self-leave: OK if joined or invited
      if sender_membership in ["join", "invite"],
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

        target_membership not in ["join", "invite"] ->
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
    sender = event["sender"]
    event_type = event["type"]
    pl = power_levels(current_state)

    required =
      get_in(pl, ["events", event_type]) ||
        Map.get(pl, "state_default", 50)

    sender_pl = effective_power(sender, pl, current_state, version)

    if sender_pl >= required,
      do: :ok,
      else: {:error, :insufficient_power}
  end

  defp check_power_level_for_send(event, current_state, version) do
    sender = event["sender"]
    event_type = event["type"]
    pl = power_levels(current_state)

    required =
      get_in(pl, ["events", event_type]) ||
        Map.get(pl, "events_default", 0)

    sender_pl = effective_power(sender, pl, current_state, version)

    if sender_pl >= required,
      do: :ok,
      else: {:error, :insufficient_power}
  end

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
      nil -> %{}
      event -> event["content"] || %{}
    end
  end

  # Room v12: creators have unconditional, infinite power — never listed in
  # power_levels.users, can never be outranked or demoted (rule: "cannot be
  # specified in the m.room.power_levels event", "infinitely high power
  # level"). Earlier versions: when no power_levels event exists yet, the
  # room creator has implicit level 100 (an empty PL event {} still counts
  # as existing → no implicit 100 in that case).
  @infinite_power 1_000_000_000

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

  defp sender_power(user_id, pl) do
    users = Map.get(pl, "users", %{})
    Map.get(users, user_id, Map.get(pl, "users_default", 0))
  end

  defp has_power?(user_id, action, current_state, version) do
    pl = power_levels(current_state)
    required = Map.get(pl, action, default_pl_for(action))
    effective_power(user_id, pl, current_state, version) >= required
  end

  defp has_power_over?(sender, target, action, current_state, version) do
    pl = power_levels(current_state)
    required = Map.get(pl, action, default_pl_for(action))
    sender_pl = effective_power(sender, pl, current_state, version)
    target_pl = effective_power(target, pl, current_state, version)
    sender_pl >= required && sender_pl > target_pl
  end

  defp default_pl_for("invite"), do: 0
  defp default_pl_for("kick"), do: 50
  defp default_pl_for("ban"), do: 50
  defp default_pl_for("redact"), do: 50
  defp default_pl_for(_), do: 50
end
