defmodule AxonRoom.EventBuilder do
  @moduledoc """
  Builds, hashes, and signs Matrix events.

  Spec: https://spec.matrix.org/latest/server-server-api/#pdus
  """

  alias AxonCrypto.{EventHash, KeyServer}

  @doc """
  Builds a complete, signed Matrix event ready for persistence.

  room_ctx: %{room_id, room_version, current_state, last_event_id, depth}
  """
  def build(sender, type, content, room_ctx, opts \\ []) do
    state_key = Keyword.get(opts, :state_key)
    server_name = KeyServer.server_name()

    prev_events =
      case room_ctx.last_event_id do
        nil -> []
        id -> [id]
      end

    auth_event_ids =
      select_auth_events(type, state_key, sender, room_ctx.current_state, room_ctx.room_version)

    skeleton = %{
      "type" => type,
      "sender" => sender,
      "content" => content,
      "origin_server_ts" => System.os_time(:millisecond),
      "origin" => server_name,
      "prev_events" => prev_events,
      "auth_events" => auth_event_ids,
      "depth" => room_ctx.depth + 1
    }

    # Room v12: the m.room.create event MUST NOT carry a room_id field (the
    # room_id IS its event ID, with "!" instead of "$" — see
    # AxonRoom.CreateRoom's v12 bootstrap, which calls this with
    # room_ctx.room_id == nil to compute that hash before the room exists).
    # Every other event keeps "room_id" as normal.
    skeleton =
      if room_ctx.room_id,
        do: Map.put(skeleton, "room_id", room_ctx.room_id),
        else: skeleton

    skeleton =
      if state_key != nil,
        do: Map.put(skeleton, "state_key", state_key),
        else: skeleton

    # Add content hash (must be done before signing)
    content_hash = EventHash.content_hash(skeleton)
    skeleton = Map.put(skeleton, "hashes", %{"sha256" => content_hash})

    # Sign
    signed = KeyServer.sign_event(skeleton)

    # Compute event_id (reference hash — room v3+ format)
    event_id = EventHash.reference_hash(signed)
    Map.put(signed, "event_id", event_id)
  end

  # ---------------------------------------------------------------------------
  # Auth event selection
  # Spec: https://spec.matrix.org/latest/server-server-api/#auth-events-selection
  # ---------------------------------------------------------------------------

  defp select_auth_events(type, state_key, sender, current_state, room_version) do
    # Room v12 (MSC4297/rule 3.2): m.room.create MUST NOT be selected as an
    # auth event for anything — its authority is implicit via room_id now
    # (rule 2: room_id must itself be the create event's ID). Versions
    # before 12 keep including it.
    create_ref =
      if room_version == "12", do: [], else: [lookup(current_state, "m.room.create", "")]

    always =
      create_ref ++
        [
          lookup(current_state, "m.room.power_levels", ""),
          lookup(current_state, "m.room.member", sender)
        ]

    extras =
      case type do
        "m.room.create" ->
          []

        "m.room.member" ->
          target = state_key

          [
            lookup(current_state, "m.room.join_rules", ""),
            lookup(current_state, "m.room.member", target)
          ]

        _ ->
          []
      end

    (always ++ extras)
    |> Enum.flat_map(fn
      nil -> []
      event -> [event["event_id"]]
    end)
    |> Enum.uniq()
  end

  defp lookup(current_state, type, state_key) do
    Map.get(current_state, {type, state_key})
  end
end
