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

    auth_event_ids = select_auth_events(type, state_key, sender, room_ctx.current_state)

    skeleton = %{
      "type" => type,
      "room_id" => room_ctx.room_id,
      "sender" => sender,
      "content" => content,
      "origin_server_ts" => System.os_time(:millisecond),
      "origin" => server_name,
      "prev_events" => prev_events,
      "auth_events" => auth_event_ids,
      "depth" => room_ctx.depth + 1
    }

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

  defp select_auth_events(type, state_key, sender, current_state) do
    always = [
      lookup(current_state, "m.room.create", ""),
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
