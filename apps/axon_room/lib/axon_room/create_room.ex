defmodule AxonRoom.CreateRoom do
  @moduledoc "Executes the room creation sequence."

  alias AxonCore.EventStore
  alias AxonRoom.{EventBuilder, RoomProcess}

  @default_version "11"

  @doc """
  Creates a new room.

  Options:
    - :name — room name (string)
    - :topic — room topic (string)
    - :preset — "public_chat" | "private_chat" | "trusted_private_chat"
    - :is_direct — boolean
    - :invite — list of user IDs to invite
    - :room_alias — localpart for alias
    - :version — room version string (default "11")
    - :server_name — this server's name
    - :power_level_content_override — map merged on top of the default
      `m.room.power_levels` content before it's sent (stable CS API param,
      not an MSC — see spec `POST /createRoom`)

  Returns `{:ok, room_id}` or `{:error, reason}`.
  """
  def execute(creator, opts \\ []) do
    server_name = opts[:server_name] || Application.fetch_env!(:axon_web, :server_name)
    version = opts[:version] || @default_version
    preset = opts[:preset] || "private_chat"
    is_public = preset == "public_chat" or opts[:visibility] == "public"
    create_content = build_create_content(creator, version, preset, opts)

    with :ok <- check_version_supported(version),
         :ok <- check_additional_creators(version, create_content),
         {:ok, power_levels} <-
           build_power_levels(creator, preset, version, create_content, opts),
         {:ok, room_id, prebuilt_create_event} <-
           resolve_room_id(opts[:room_id], version, server_name, creator, create_content),
         {:ok, _} <- EventStore.insert_room(room_id, creator, version, is_public),
         {:ok, _pid} <- RoomProcess.get_or_start(room_id),
         :ok <- maybe_inject_create_event(room_id, prebuilt_create_event),
         :ok <-
           send_initial_events(
             room_id,
             creator,
             preset,
             opts,
             create_content,
             prebuilt_create_event,
             power_levels
           ) do
      # Handle alias registration
      if alias_localpart = opts[:room_alias_name] do
        room_alias = "##{alias_localpart}:#{server_name}"
        register_alias(room_alias, room_id, creator)

        RoomProcess.send_event(
          room_id,
          creator,
          "m.room.canonical_alias",
          %{"alias" => room_alias},
          state_key: ""
        )
      end

      # Invite initial members. Per spec, createRoom's top-level is_direct
      # flag is echoed onto each invite's own m.room.member content — it's
      # how the invitee's client knows to treat the room as a DM before
      # they've joined and can see any other state.
      invite_content =
        if opts[:is_direct],
          do: %{"membership" => "invite", "is_direct" => true},
          else: %{"membership" => "invite"}

      Enum.each(opts[:invite] || [], fn invitee ->
        RoomProcess.send_event(room_id, creator, "m.room.member", invite_content,
          state_key: invitee
        )
      end)

      {:ok, room_id}
    end
  end

  defp send_initial_events(
         room_id,
         creator,
         preset,
         opts,
         create_content,
         prebuilt_create_event,
         power_levels
       ) do
    {join_rule, history_visibility, guest_access} = preset_values(preset)

    # Order matters: each event references the previous as prev_event.
    # When the create event was already bootstrapped standalone (room v12 —
    # see resolve_room_id/5), it's already been injected into the room by
    # the time we get here; don't send it (and hence build/auth-check it) a
    # second time.
    create_event_step =
      if prebuilt_create_event, do: [], else: [{"m.room.create", "", create_content}]

    events =
      create_event_step ++
        [
          # Creator joins
          {"m.room.member", creator,
           %{
             "membership" => "join",
             "displayname" => opts[:creator_displayname]
           }},
          # Power levels
          {"m.room.power_levels", "", power_levels},
          # Join rules
          {"m.room.join_rules", "", %{"join_rule" => join_rule}},
          # History visibility
          {"m.room.history_visibility", "", %{"history_visibility" => history_visibility}},
          # Guest access
          {"m.room.guest_access", "", %{"guest_access" => guest_access}}
        ]

    # Optional metadata events from initial_state (before name/topic)
    initial_state_events =
      (opts[:initial_state] || [])
      |> Enum.map(fn ev ->
        {ev["type"], ev["state_key"] || "", ev["content"] || %{}}
      end)

    # Name / topic come after initial_state (topic with rich format overrides initial_state topic)
    events =
      events ++
        initial_state_events ++
        maybe_name_event(opts[:name]) ++
        maybe_topic_event(opts[:topic])

    Enum.reduce_while(events, :ok, fn {type, state_key, content}, _acc ->
      send_opts = [state_key: state_key]

      case RoomProcess.send_event(room_id, creator, type, content, send_opts) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp preset_values("public_chat"), do: {"public", "shared", "can_join"}
  defp preset_values("trusted_private_chat"), do: {"invite", "shared", "forbidden"}
  defp preset_values(_), do: {"invite", "shared", "forbidden"}

  defp default_power_levels(creator, preset, version) do
    invite_level = if preset == "trusted_private_chat", do: 0, else: 50

    # Room v12 (rule 10.4): the users map MUST NOT contain the creator(s) —
    # they get implicit infinite power instead (see AuthRules). Pre-v12
    # rooms still need the explicit users => 100 entry since there's no
    # other way for the creator to hold power there.
    users = if version == "12", do: %{}, else: %{creator => 100}

    # Room v12 (MSC4289): m.room.tombstone needs a power level explicitly
    # higher than state_default (100) — only a creator (implicit infinite
    # power) should be able to tombstone/upgrade a v12 room by default,
    # since ordinary admins are capped at whatever they were explicitly
    # granted. Every other default is unchanged between room versions.
    tombstone_level = if version == "12", do: 150, else: 100

    %{
      "users" => users,
      "users_default" => 0,
      "events" => %{
        "m.room.name" => 50,
        "m.room.power_levels" => 100,
        "m.room.history_visibility" => 100,
        "m.room.canonical_alias" => 50,
        "m.room.avatar" => 50,
        "m.room.tombstone" => tombstone_level,
        "m.room.server_acl" => 100,
        "m.room.encryption" => 100
      },
      "events_default" => 0,
      "state_default" => 50,
      "ban" => 50,
      "kick" => 50,
      "redact" => 50,
      "invite" => invite_level
    }
  end

  # ---------------------------------------------------------------------------
  # power_level_content_override (stable CS API createRoom param — see spec
  # https://spec.matrix.org/latest/client-server-api/#post_matrixclientv3createroom
  # and data/api/client-server/create_room.yaml in matrix-spec). "This object
  # is applied on top of the generated m.room.power_levels event content
  # prior to it being sent to the room" — a *shallow* merge (confirmed
  # against Synapse's reference implementation, which does a plain
  # `dict.update`): each top-level key in the override wholly replaces the
  # corresponding default key (e.g. supplying "events" replaces the entire
  # default events map, it does not merge key-by-key within it).
  # ---------------------------------------------------------------------------

  defp build_power_levels(creator, preset, version, create_content, opts) do
    defaults = default_power_levels(creator, preset, version)

    case opts[:power_level_content_override] do
      nil ->
        {:ok, defaults}

      override when is_map(override) ->
        with :ok <- check_override_leaves_creator_administrable(version, creator, override) do
          merged = Map.merge(defaults, override)
          check_creators_excluded_from_merged_power_levels(version, create_content, merged)
        end

      _ ->
        {:error, :invalid_power_level_content_override}
    end
  end

  # Pre-v12: the creator's only path to power is the explicit users => 100
  # entry a default power_levels event would otherwise carry. If a client's
  # override supplies its own "users" map without including the creator,
  # honoring it verbatim would create a room its own creator can't
  # administer — which the spec says the server must not allow. (Room v12
  # has no such concern: creators there never appear in `users` at all,
  # having implicit infinite power instead — see the *_excluded_from_merged
  # check below for v12's own invariant.)
  defp check_override_leaves_creator_administrable("12", _creator, _override), do: :ok

  defp check_override_leaves_creator_administrable(_version, creator, override) do
    case Map.get(override, "users") do
      users when is_map(users) ->
        if Map.has_key?(users, creator),
          do: :ok,
          else: {:error, :power_level_content_override_excludes_creator}

      _ ->
        :ok
    end
  end

  # Room v12 rule 10.4: content.users must never list a creator (primary or
  # additional) — not just for client-sent m.room.power_levels state events
  # (AuthRules enforces that), but for the power_level_content_override path
  # too, since that content is what actually gets sent as the room's first
  # m.room.power_levels event. Unlike AuthRules rejecting a *later* PUT,
  # this runs before the room exists at all, so there's no orphaned-room
  # cleanup concern.
  defp check_creators_excluded_from_merged_power_levels("12", create_content, merged) do
    creators = MapSet.new(creator_ids_from_create_content(create_content))
    users = Map.get(merged, "users")

    excluded? =
      is_map(users) and Enum.any?(Map.keys(users), &MapSet.member?(creators, &1))

    if excluded?,
      do: {:error, :power_levels_may_not_list_creators},
      else: {:ok, merged}
  end

  defp check_creators_excluded_from_merged_power_levels(_version, _create_content, merged),
    do: {:ok, merged}

  defp creator_ids_from_create_content(create_content) do
    primary = create_content["creator"]
    additional = create_content["additional_creators"] || []
    [primary | additional]
  end

  defp maybe_name_event(nil), do: []
  defp maybe_name_event(name), do: [{"m.room.name", "", %{"name" => name}}]

  defp maybe_topic_event(nil), do: []

  defp maybe_topic_event(topic) do
    # MSC3765: include rich topic representation alongside plain text
    content = %{
      "topic" => topic,
      "m.topic" => %{
        "m.text" => [%{"body" => topic, "mimetype" => "text/plain"}]
      }
    }

    [{"m.room.topic", "", content}]
  end

  @doc "Generates a fresh random room_id for `server_name`. Public so callers (e.g. pre-v12 room upgrades) can pre-generate one."
  def generate_room_id(server_name) do
    random = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    "!#{random}:#{server_name}"
  end

  @doc "Whether `v` is a supported room version string."
  def check_version_supported(v) when v in ~w(2 3 4 5 6 7 8 9 10 11 12), do: :ok
  def check_version_supported(_), do: {:error, :unsupported_room_version}

  # ---------------------------------------------------------------------------
  # Room v12 bootstrap: room IDs are the create event's own event ID (with
  # "!" instead of "$" — MSC4297), so the event must be built and hashed
  # before the room "exists" anywhere (DB row, RoomProcess). Every other
  # version keeps its pre-generated `!random:server_name` room_id, built
  # into the create event like any other state event.
  # ---------------------------------------------------------------------------

  defp build_create_content(creator, version, preset, opts) do
    # additional_creators (room v12 / MSC4289) is an ordinary creation_content
    # field from the client's perspective — same mechanism as `predecessor` —
    # not a separate top-level createRoom param.
    extra_create_content =
      case opts[:creation_content] do
        nil -> %{}
        cc when is_map(cc) -> Map.drop(cc, ["room_version", "creator"])
        _ -> %{}
      end

    %{"creator" => creator, "room_version" => version, "m.federate" => true}
    |> Map.merge(extra_create_content)
    |> Map.put("creator", creator)
    |> Map.put("room_version", version)
    |> maybe_add_trusted_private_chat_creators(version, preset, opts[:invite] || [])
  end

  # createRoom spec (data/api/client-server/create_room.yaml, "Added server
  # behaviour for how to handle trusted_private_chat and invited users",
  # Matrix 1.16+): "When using the trusted_private_chat preset, the server
  # SHOULD combine additional_creators specified here and the invite array
  # into the eventual m.room.create event's additional_creators,
  # deduplicating between the two parameters." This is v12-specific in
  # practice — pre-v12 rooms have no additional_creators mechanism at all
  # (trusted_private_chat there instead grants invitees PL equal to the
  # creator directly, unrelated to this). Confirmed against Synapse's
  # reference implementation, which gates this identically on
  # `msc4289_creator_power_enabled and preset == trusted_private_chat and
  # len(invite) > 0` — *not* on `is_direct` (a separate, orthogonal flag
  # that only stamps `m.room.member` events for DM UI purposes).
  defp maybe_add_trusted_private_chat_creators(content, "12", "trusted_private_chat", invite)
       when invite != [] do
    existing = content["additional_creators"] || []
    Map.put(content, "additional_creators", Enum.uniq(existing ++ invite))
  end

  defp maybe_add_trusted_private_chat_creators(content, _version, _preset, _invite), do: content

  # Rule 1 (v12): additional_creators, if present, must be an array of
  # strings each passing the same user ID validation as `sender`. Public so
  # AxonRoom.RoomUpgrade (additional_creators on POST /upgrade) can validate
  # against the same rule without duplicating it.
  def check_additional_creators("12", %{"additional_creators" => list}) do
    if valid_additional_creators?(list),
      do: :ok,
      else: {:error, :invalid_additional_creators}
  end

  def check_additional_creators(_version, _content), do: :ok

  @doc "Whether `list` is a non-empty array of well-formed user ID strings (room v12 additional_creators)."
  def valid_additional_creators?(list) when is_list(list) and list != [] do
    Enum.all?(list, &valid_user_id?/1)
  end

  def valid_additional_creators?(_), do: false

  # Server-name grammar is intentionally conservative here (registered
  # hostname / IPv4 literal + optional ":port"; no IPv6-bracket support) —
  # good enough to catch garbage like "dom$ain$.com" without trying to be a
  # full RFC 1035/3986 validator. Kept in sync by hand with the equivalent
  # check in AxonRoom.AuthRules.valid_user_id?/1 (which re-validates every
  # additional_creators entry independently when the create event is
  # auth-checked, so this copy diverging would not be exploitable
  # end-to-end — but should still be fixed/deduplicated together).
  @server_name_regex ~r/^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)*(?::[0-9]{1,5})?$/

  defp valid_user_id?(id) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      ["@" <> localpart, domain] ->
        localpart != "" and domain != "" and Regex.match?(@server_name_regex, domain)

      _ ->
        false
    end
  end

  defp valid_user_id?(_), do: false

  # v12, no explicit room_id override: build+hash the create event standalone
  # to derive the room_id. Explicit room_id (v12 room upgrades — see
  # AxonRoom.RoomUpgrade, which must create the new room before it can
  # reference the new room_id in the old room's tombstone, so there's
  # nothing to bootstrap here either way) or any pre-v12 version: keep the
  # existing pre-generated-random-id behavior untouched.
  defp resolve_room_id(nil, "12", _server_name, creator, create_content) do
    room_ctx = %{
      room_id: nil,
      room_version: "12",
      current_state: %{},
      last_event_id: nil,
      depth: 0
    }

    create_event =
      EventBuilder.build(creator, "m.room.create", create_content, room_ctx, state_key: "")

    room_id = String.replace_prefix(create_event["event_id"], "$", "!")
    {:ok, room_id, Map.put(create_event, "room_id", room_id)}
  end

  defp resolve_room_id(explicit_room_id, _version, server_name, _creator, _create_content) do
    {:ok, explicit_room_id || generate_room_id(server_name), nil}
  end

  defp maybe_inject_create_event(_room_id, nil), do: :ok

  defp maybe_inject_create_event(room_id, create_event) do
    case RoomProcess.apply_remote_event(room_id, create_event) do
      {:ok, _event_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_alias(room_alias, room_id, creator) do
    AxonCore.Repo.insert_all(
      "room_aliases",
      [
        %{
          alias: room_alias,
          room_id: room_id,
          creator: creator,
          inserted_at: DateTime.utc_now(:microsecond),
          updated_at: DateTime.utc_now(:microsecond)
        }
      ],
      on_conflict: :nothing
    )
  end
end
