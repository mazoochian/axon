defmodule AxonRoom.RestrictedJoin do
  @moduledoc """
  MSC3083 restricted joins: `join_rule: "restricted"` (and `"knock_restricted"`)
  lets a user join without an invite if they're a member of one of the rooms
  named in the `allow` list (normally a space the room is part of).

  Unlike `AxonRoom.AuthRules`, this module needs cross-room membership data,
  so it isn't pure — it queries `room_memberships` directly. It's meant to be
  called by whichever server is about to authorise a join (the resident
  server handling a local join or a federation `make_join`), before the join
  event is built. The result gets stamped onto the event as
  `join_authorised_via_users_server`, which `AuthRules` then verifies.
  """

  alias AxonCore.Repo
  import Ecto.Query

  @doc """
  Checks whether `user_id` satisfies the room's allow-list and, if so, picks
  a local user already joined to the room (per `current_state`) with invite
  power to vouch for it.

  Returns `{:ok, authoriser_user_id}` or `{:error, :restricted_join_denied}`.
  """
  def authorise(join_rule_content, user_id, current_state) do
    allow = join_rule_content["allow"] || []

    if allow != [] and satisfies_allow_rule?(allow, user_id) do
      case pick_authoriser(current_state) do
        nil -> {:error, :restricted_join_denied}
        authoriser -> {:ok, authoriser}
      end
    else
      {:error, :restricted_join_denied}
    end
  end

  defp satisfies_allow_rule?(allow, user_id) do
    allow
    |> Enum.filter(&(&1["type"] == "m.room_membership"))
    |> Enum.map(& &1["room_id"])
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&joined?(&1, user_id))
  end

  defp joined?(room_id, user_id) do
    Repo.exists?(
      from(m in "room_memberships",
        where: m.room_id == ^room_id and m.user_id == ^user_id and m.membership == "join"
      )
    )
  end

  # Any local user currently joined to the room with invite power can vouch
  # for the join — their server signs the resulting event, which is what
  # AuthRules trusts on every other server that later validates it.
  defp pick_authoriser(current_state) do
    local_server = Application.get_env(:axon_web, :server_name, "localhost")
    version = room_version(current_state)

    current_state
    |> Enum.filter(fn
      {{"m.room.member", target_user_id}, event} ->
        get_in(event, ["content", "membership"]) == "join" and
          server_of(target_user_id) == local_server

      _ ->
        false
    end)
    |> Enum.map(fn {{_type, target_user_id}, _event} -> target_user_id end)
    |> Enum.find(&AxonRoom.AuthRules.can_invite?(&1, current_state, version))
  end

  # A creator's implicit infinite power (room v12) only kicks in when
  # AuthRules knows the room's actual version — current_state carries it via
  # the create event's own content, so there's no need for callers to thread
  # a separate room_version parameter through just for this.
  defp room_version(current_state) do
    case current_state[{"m.room.create", ""}] do
      %{"content" => %{"room_version" => v}} -> v
      _ -> "11"
    end
  end

  defp server_of(user_id), do: user_id |> String.split(":") |> List.last()
end
