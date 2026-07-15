defmodule AxonRoom.RestrictedJoinTest do
  @moduledoc """
  Tests `AxonRoom.RestrictedJoin.authorise/3` (MSC3083) against a real
  `room_memberships` table — the one piece of restricted-join logic that
  isn't pure (it needs cross-room membership data).
  """

  use AxonRoom.DataCase, async: false

  alias AxonRoom.RestrictedJoin

  @space_room "!space:localhost"
  @target_room "!target:localhost"
  @alice "@alice:localhost"
  @creator "@creator:localhost"

  defp insert_user(user_id) do
    localpart = user_id |> String.trim_leading("@") |> String.split(":") |> hd()
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "users",
      [
        %{
          user_id: user_id,
          localpart: localpart,
          is_guest: false,
          deactivated: false,
          admin: false,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )
  end

  defp insert_room(room_id, creator) do
    now = DateTime.utc_now(:microsecond)
    insert_user(creator)

    Repo.insert_all(
      "rooms",
      [
        %{
          room_id: room_id,
          version: "10",
          creator: creator,
          is_public: false,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )
  end

  defp insert_membership(room_id, user_id, membership) do
    now = DateTime.utc_now(:microsecond)
    insert_user(user_id)

    Repo.insert_all(
      "room_memberships",
      [
        %{
          room_id: room_id,
          user_id: user_id,
          membership: membership,
          event_id: "$#{System.unique_integer([:positive])}",
          sender: user_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:membership]},
      conflict_target: [:room_id, :user_id]
    )
  end

  defp member_event(user_id, membership) do
    %{
      "type" => "m.room.member",
      "state_key" => user_id,
      "content" => %{"membership" => membership}
    }
  end

  setup do
    insert_room(@space_room, @creator)
    insert_room(@target_room, @creator)
    :ok
  end

  test "denied when allow is empty" do
    assert RestrictedJoin.authorise(%{"allow" => []}, @alice, %{}) ==
             {:error, :restricted_join_denied}
  end

  test "denied when allow only lists an unrecognized rule type" do
    allow = [%{"type" => "something_else", "room_id" => @space_room}]

    assert RestrictedJoin.authorise(%{"allow" => allow}, @alice, %{}) ==
             {:error, :restricted_join_denied}
  end

  test "denied when user isn't joined to any allow-listed room" do
    allow = [%{"type" => "m.room_membership", "room_id" => @space_room}]

    assert RestrictedJoin.authorise(%{"allow" => allow}, @alice, %{}) ==
             {:error, :restricted_join_denied}
  end

  test "denied when user is joined to the allow-listed room but no local authoriser is available" do
    insert_membership(@space_room, @alice, "join")
    allow = [%{"type" => "m.room_membership", "room_id" => @space_room}]

    # current_state has no joined member with invite power to vouch.
    assert RestrictedJoin.authorise(%{"allow" => allow}, @alice, %{}) ==
             {:error, :restricted_join_denied}
  end

  test "authorised when user is joined to an allow-listed room and a local member can vouch" do
    insert_membership(@space_room, @alice, "join")
    allow = [%{"type" => "m.room_membership", "room_id" => @space_room}]

    current_state = %{{"m.room.member", @creator} => member_event(@creator, "join")}
    assert RestrictedJoin.authorise(%{"allow" => allow}, @alice, current_state) == {:ok, @creator}
  end

  test "checks every room in a multi-room allow list (any-of semantics)" do
    insert_membership(@target_room, @alice, "join")

    allow = [
      %{"type" => "m.room_membership", "room_id" => @space_room},
      %{"type" => "m.room_membership", "room_id" => @target_room}
    ]

    current_state = %{{"m.room.member", @creator} => member_event(@creator, "join")}
    assert RestrictedJoin.authorise(%{"allow" => allow}, @alice, current_state) == {:ok, @creator}
  end

  test "a leave membership in the allow-listed room does not satisfy the rule" do
    insert_membership(@space_room, @alice, "leave")
    allow = [%{"type" => "m.room_membership", "room_id" => @space_room}]

    current_state = %{{"m.room.member", @creator} => member_event(@creator, "join")}

    assert RestrictedJoin.authorise(%{"allow" => allow}, @alice, current_state) ==
             {:error, :restricted_join_denied}
  end

  test "only a member with sufficient invite power is picked as authoriser" do
    insert_membership(@space_room, @alice, "join")
    allow = [%{"type" => "m.room_membership", "room_id" => @space_room}]

    # Bob is joined locally but power_levels denies him invite power; only
    # the creator (implicit power 100, no explicit power_levels event) qualifies.
    current_state = %{
      {"m.room.member", "@bob:localhost"} => member_event("@bob:localhost", "join"),
      {"m.room.member", @creator} => member_event(@creator, "join"),
      {"m.room.power_levels", ""} => %{
        "type" => "m.room.power_levels",
        "content" => %{"invite" => 50, "users" => %{"@bob:localhost" => 0, @creator => 100}}
      }
    }

    assert RestrictedJoin.authorise(%{"allow" => allow}, @alice, current_state) == {:ok, @creator}
  end

  test "a joined member on a different (remote) server is never picked as authoriser" do
    insert_membership(@space_room, @alice, "join")
    allow = [%{"type" => "m.room_membership", "room_id" => @space_room}]

    remote_user = "@remote_admin:example.org"
    current_state = %{{"m.room.member", remote_user} => member_event(remote_user, "join")}

    assert RestrictedJoin.authorise(%{"allow" => allow}, @alice, current_state) ==
             {:error, :restricted_join_denied}
  end
end
