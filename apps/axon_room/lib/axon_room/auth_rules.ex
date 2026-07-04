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
  def can_invite?(user_id, current_state), do: has_power?(user_id, "invite", current_state)

  # ---------------------------------------------------------------------------
  # m.room.create — must be the first event
  # ---------------------------------------------------------------------------

  defp check_type_specific(%{"type" => "m.room.create"} = event, current_state, _version) do
    cond do
      # Room already has a create event
      Map.has_key?(current_state, {"m.room.create", ""}) ->
        {:error, :room_already_created}

      # prev_events must be empty
      event["prev_events"] != [] ->
        {:error, :create_event_has_prev_events}

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

  defp check_type_specific(%{"type" => "m.room.power_levels"} = event, current_state, _version) do
    with :ok <- check_sender_joined(event, current_state),
         :ok <- check_power_level_for_state(event, current_state) do
      :ok
    end
  end

  defp check_type_specific(%{"state_key" => _} = event, current_state, _version) do
    # Generic state event
    with :ok <- check_sender_joined(event, current_state),
         :ok <- check_power_level_for_state(event, current_state) do
      :ok
    end
  end

  defp check_type_specific(event, current_state, _version) do
    # Message / non-state event
    with :ok <- check_sender_joined(event, current_state),
         :ok <- check_power_level_for_send(event, current_state) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # m.room.member detail
  # ---------------------------------------------------------------------------

  defp check_member_event(event, current_state, _version) do
    sender = event["sender"]
    target = event["state_key"]
    membership = get_in(event, ["content", "membership"])

    case membership do
      "join" -> check_join(event, sender, target, current_state)
      "invite" -> check_invite(sender, target, current_state)
      "leave" -> check_leave(sender, target, current_state)
      "ban" -> check_ban(sender, target, current_state)
      "knock" -> check_knock(sender, target, current_state)
      _ -> {:error, :invalid_membership}
    end
  end

  defp check_join(event, sender, target, current_state) do
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

          join_rule in ["public", "open"] ->
            :ok

          join_rule == "invite" ->
            # Allow if invited OR if the room creator (initial join before join_rules event exists)
            if sender_membership == "invite" or room_creator?(sender, current_state),
              do: :ok,
              else: {:error, :not_invited}

          join_rule in ["restricted", "knock_restricted"] ->
            check_restricted_join(event, sender, sender_membership, current_state)

          join_rule == "knock" ->
            if sender_membership in ["invite", "knock"], do: :ok, else: {:error, :not_invited}

          true ->
            {:error, :not_invited}
        end
    end
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
  defp check_restricted_join(event, sender, sender_membership, current_state) do
    authoriser = get_in(event, ["content", "join_authorised_via_users_server"])

    cond do
      sender_membership == "invite" or room_creator?(sender, current_state) ->
        :ok

      is_binary(authoriser) and current_membership(authoriser, current_state) == "join" and
          has_power?(authoriser, "invite", current_state) ->
        :ok

      true ->
        {:error, :not_invited}
    end
  end

  defp check_invite(sender, target, current_state) do
    sender_membership = current_membership(sender, current_state)
    target_membership = current_membership(target, current_state)

    cond do
      sender_membership != "join" ->
        {:error, :not_joined}

      target_membership == "ban" ->
        {:error, :target_banned}

      target_membership == "join" ->
        {:error, :already_joined}

      not has_power?(sender, "invite", current_state) ->
        {:error, :insufficient_power}

      true ->
        :ok
    end
  end

  defp check_leave(sender, target, current_state) do
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
          if has_power?(sender, "ban", current_state),
            do: :ok,
            else: {:error, :insufficient_power}

        target_membership not in ["join", "invite"] ->
          {:error, :target_not_in_room}

        not has_power_over?(sender, target, "kick", current_state) ->
          {:error, :insufficient_power}

        true ->
          :ok
      end
    end
  end

  defp check_ban(sender, target, current_state) do
    sender_membership = current_membership(sender, current_state)

    cond do
      sender_membership != "join" ->
        {:error, :not_joined}

      not has_power_over?(sender, target, "ban", current_state) ->
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

  defp check_power_level_for_state(event, current_state) do
    sender = event["sender"]
    event_type = event["type"]
    pl = power_levels(current_state)

    required =
      get_in(pl, ["events", event_type]) ||
        Map.get(pl, "state_default", 50)

    sender_pl = effective_power(sender, pl, current_state)

    if sender_pl >= required,
      do: :ok,
      else: {:error, :insufficient_power}
  end

  defp check_power_level_for_send(event, current_state) do
    sender = event["sender"]
    event_type = event["type"]
    pl = power_levels(current_state)

    required =
      get_in(pl, ["events", event_type]) ||
        Map.get(pl, "events_default", 0)

    sender_pl = effective_power(sender, pl, current_state)

    if sender_pl >= required,
      do: :ok,
      else: {:error, :insufficient_power}
  end

  # ---------------------------------------------------------------------------
  # State helpers
  # ---------------------------------------------------------------------------

  defp room_creator?(user_id, current_state) do
    case current_state[{"m.room.create", ""}] do
      nil -> false
      event -> get_in(event, ["content", "creator"]) == user_id
    end
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

  # When no power_levels event exists yet, the room creator has implicit level 100.
  # An empty PL event {} still exists → creator does NOT get implicit 100 in that case.
  defp effective_power(user_id, pl, current_state) do
    has_pl_event = Map.has_key?(current_state, {"m.room.power_levels", ""})

    if not has_pl_event and room_creator?(user_id, current_state),
      do: 100,
      else: sender_power(user_id, pl)
  end

  defp sender_power(user_id, pl) do
    users = Map.get(pl, "users", %{})
    Map.get(users, user_id, Map.get(pl, "users_default", 0))
  end

  defp has_power?(user_id, action, current_state) do
    pl = power_levels(current_state)
    required = Map.get(pl, action, default_pl_for(action))
    effective_power(user_id, pl, current_state) >= required
  end

  defp has_power_over?(sender, target, action, current_state) do
    pl = power_levels(current_state)
    required = Map.get(pl, action, default_pl_for(action))
    sender_pl = effective_power(sender, pl, current_state)
    target_pl = sender_power(target, pl)
    sender_pl >= required && sender_pl > target_pl
  end

  defp default_pl_for("invite"), do: 0
  defp default_pl_for("kick"), do: 50
  defp default_pl_for("ban"), do: 50
  defp default_pl_for("redact"), do: 50
  defp default_pl_for(_), do: 50
end
