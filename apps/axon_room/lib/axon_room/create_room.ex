defmodule AxonRoom.CreateRoom do
  @moduledoc "Executes the room creation sequence."

  alias AxonCore.EventStore
  alias AxonRoom.RoomProcess

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
    room_id = opts[:room_id] || generate_room_id(server_name)

    is_public = preset == "public_chat" or opts[:visibility] == "public"

    with :ok <- check_version_supported(version),
         {:ok, _} <- EventStore.insert_room(room_id, creator, version, is_public),
         {:ok, _pid} <- RoomProcess.get_or_start(room_id),
         :ok <- send_initial_events(room_id, creator, preset, opts) do
      # Handle alias registration
      if alias_localpart = opts[:room_alias_name] do
        room_alias = "##{alias_localpart}:#{server_name}"
        register_alias(room_alias, room_id, creator)
        RoomProcess.send_event(room_id, creator, "m.room.canonical_alias", %{"alias" => room_alias}, state_key: "")
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

  defp send_initial_events(room_id, creator, preset, opts) do
    {join_rule, history_visibility, guest_access} = preset_values(preset)

    # Merge creation_content but never allow overriding room_version
    extra_create_content =
      case opts[:creation_content] do
        nil -> %{}
        cc when is_map(cc) -> Map.drop(cc, ["room_version"])
        _ -> %{}
      end

    create_content =
      %{"creator" => creator, "room_version" => opts[:version] || @default_version, "m.federate" => true}
      |> Map.merge(extra_create_content)
      |> Map.put("creator", creator)
      |> Map.put("room_version", opts[:version] || @default_version)

    # Order matters: each event references the previous as prev_event
    events = [
      # 1. m.room.create
      {"m.room.create", "", create_content},
      # 2. Creator joins
      {"m.room.member", creator,
       %{
         "membership" => "join",
         "displayname" => opts[:creator_displayname]
       }},
      # 3. Power levels
      {"m.room.power_levels", "",
       default_power_levels(creator, preset)},
      # 4. Join rules
      {"m.room.join_rules", "", %{"join_rule" => join_rule}},
      # 5. History visibility
      {"m.room.history_visibility", "", %{"history_visibility" => history_visibility}},
      # 6. Guest access
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

  defp default_power_levels(creator, preset) do
    invite_level = if preset == "trusted_private_chat", do: 0, else: 50

    %{
      "users" => %{creator => 100},
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

  @doc "Generates a fresh random room_id for `server_name`. Public so callers (e.g. room upgrades) can pre-generate one."
  def generate_room_id(server_name) do
    random = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    "!#{random}:#{server_name}"
  end

  @doc "Whether `v` is a supported room version string."
  def check_version_supported(v) when v in ~w(2 3 4 5 6 7 8 9 10 11), do: :ok
  def check_version_supported(_), do: {:error, :unsupported_room_version}

  defp register_alias(room_alias, room_id, creator) do
    AxonCore.Repo.insert_all("room_aliases", [
      %{
        alias: room_alias,
        room_id: room_id,
        creator: creator,
        inserted_at: DateTime.utc_now(:microsecond),
        updated_at: DateTime.utc_now(:microsecond)
      }
    ], on_conflict: :nothing)
  end
end
