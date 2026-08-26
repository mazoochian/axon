defmodule AxonWeb.SyncSummaryTest do
  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  defp sync(token) do
    conn = authed(token) |> get("/_matrix/client/v3/sync?timeout=0")
    assert conn.status == 200
    decode(conn)
  end

  defp join_room(token, room_id) do
    conn = authed(token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
    assert conn.status == 200
  end

  test "joined room summary counts its creator and invitee" do
    creator = register("sync_summary_creator_#{System.unique_integer([:positive])}")
    invitee = register("sync_summary_invitee_#{System.unique_integer([:positive])}")

    room_id =
      create_room(creator.token, %{"name" => "Summary", "invite" => [invitee.user_id]})

    assert get_in(sync(creator.token), ["rooms", "join", room_id, "summary"]) == %{
             "m.joined_member_count" => 1,
             "m.invited_member_count" => 1
           }
  end

  test "joined room summary updates for creator and invitee after the invitee joins" do
    creator = register("sync_summary_join_creator_#{System.unique_integer([:positive])}")
    invitee = register("sync_summary_join_invitee_#{System.unique_integer([:positive])}")

    room_id =
      create_room(creator.token, %{"name" => "Summary", "invite" => [invitee.user_id]})

    join_room(invitee.token, room_id)

    expected = %{
      "m.joined_member_count" => 2,
      "m.invited_member_count" => 0
    }

    assert get_in(sync(creator.token), ["rooms", "join", room_id, "summary"]) == expected
    assert get_in(sync(invitee.token), ["rooms", "join", room_id, "summary"]) == expected
  end
end
