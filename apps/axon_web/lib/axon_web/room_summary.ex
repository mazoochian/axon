defmodule AxonWeb.RoomSummary do
  @moduledoc """
  The public summary of a local room (name, topic, join rule, member count,
  ...) shared by `/publicRooms` chunks, `/hierarchy` entries and
  `/room_summary`.
  """

  import Ecto.Query
  import AxonCore.MapUtil, only: [maybe_put: 3]
  alias AxonCore.Repo

  @summary_types [
    "m.room.name",
    "m.room.topic",
    "m.room.avatar",
    "m.room.canonical_alias",
    "m.room.history_visibility",
    "m.room.guest_access",
    "m.room.join_rules",
    "m.room.create",
    "m.room.encryption"
  ]

  @doc "Current-state contents of `types` in `room_id`, keyed by event type (state_key ignored)."
  def current_state(room_id, types) do
    Repo.all(
      from(s in "current_room_state",
        join: e in "events",
        on: e.event_id == s.event_id,
        where: s.room_id == ^room_id and s.type in ^types,
        select: %{type: s.type, content: e.content}
      )
    )
    |> Map.new(fn r -> {r.type, r.content} end)
  end

  @doc "Builds the summary; `default_join_rule` applies when the room has no m.room.join_rules."
  def build(room_id, default_join_rule) do
    state = current_state(room_id, @summary_types)

    num_joined =
      Repo.one(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.membership == "join",
          select: count(m.user_id)
        )
      ) || 0

    history_visibility =
      get_in(state, ["m.room.history_visibility", "history_visibility"]) || "shared"

    guest_access = get_in(state, ["m.room.guest_access", "guest_access"]) || "forbidden"
    join_rule = get_in(state, ["m.room.join_rules", "join_rule"]) || default_join_rule

    %{
      "room_id" => room_id,
      "num_joined_members" => num_joined,
      "world_readable" => history_visibility == "world_readable",
      "guest_can_join" => guest_access == "can_join",
      "join_rule" => join_rule
    }
    |> maybe_put("name", get_in(state, ["m.room.name", "name"]))
    |> maybe_put("topic", get_in(state, ["m.room.topic", "topic"]))
    |> maybe_put("avatar_url", get_in(state, ["m.room.avatar", "url"]))
    |> maybe_put("canonical_alias", get_in(state, ["m.room.canonical_alias", "alias"]))
    |> maybe_put("room_type", get_in(state, ["m.room.create", "type"]))
    |> maybe_put("encryption", get_in(state, ["m.room.encryption", "algorithm"]))
    |> maybe_put("allowed_room_ids", allowed_room_ids(join_rule, state))
  end

  @doc "Room IDs named by `m.room_membership` entries of a restricted join rule's `allow` list."
  def allow_room_ids(state) do
    case get_in(state, ["m.room.join_rules", "allow"]) do
      allow when is_list(allow) ->
        for %{"type" => "m.room_membership", "room_id" => id} <- allow, is_binary(id), do: id

      _ ->
        []
    end
  end

  defp allowed_room_ids(join_rule, state) when join_rule in ["restricted", "knock_restricted"] do
    case allow_room_ids(state) do
      [] -> nil
      ids -> ids
    end
  end

  defp allowed_room_ids(_join_rule, _state), do: nil
end
