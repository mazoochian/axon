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

  Returns `{:ok, room_id}` or `{:error, reason}`.
  """
  def execute(creator, opts \\ []) do
    server_name = opts[:server_name] || Application.fetch_env!(:axon_web, :server_name)
    version = opts[:version] || @default_version
    preset = opts[:preset] || "private_chat"
    is_public = preset == "public_chat" or opts[:visibility] == "public"
    create_content = build_create_content(creator, version, opts)

    with :ok <- check_version_supported(version),
         :ok <- check_additional_creators(version, create_content),
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
             prebuilt_create_event
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

      # Invite initial members
      Enum.each(opts[:invite] || [], fn invitee ->
        RoomProcess.send_event(room_id, creator, "m.room.member", %{"membership" => "invite"},
          state_key: invitee
        )
      end)

      {:ok, room_id}
    end
  end

  defp send_initial_events(room_id, creator, preset, opts, create_content, prebuilt_create_event) do
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
          {"m.room.power_levels", "",
           default_power_levels(creator, preset, create_content["room_version"])},
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

    %{
      "users" => users,
      "users_default" => 0,
      "events" => %{
        "m.room.name" => 50,
        "m.room.power_levels" => 100,
        "m.room.history_visibility" => 100,
        "m.room.canonical_alias" => 50,
        "m.room.avatar" => 50,
        "m.room.tombstone" => 100,
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

  defp build_create_content(creator, version, opts) do
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
  end

  # Rule 1 (v12): additional_creators, if present, must be an array of
  # strings each passing the same user ID validation as `sender`.
  defp check_additional_creators("12", %{"additional_creators" => list}) do
    if is_list(list) and list != [] and Enum.all?(list, &valid_user_id?/1),
      do: :ok,
      else: {:error, :invalid_additional_creators}
  end

  defp check_additional_creators(_version, _content), do: :ok

  defp valid_user_id?(id) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      ["@" <> localpart, domain] -> localpart != "" and domain != ""
      _ -> false
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
