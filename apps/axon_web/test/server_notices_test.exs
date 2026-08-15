defmodule AxonWeb.ServerNoticesTest do
  @moduledoc """
  Regression tests for Phase 14's server notices: an admin-triggered
  message from a lazily-provisioned system account (`@_server:...`) into
  an auto-created, reused-per-recipient room tagged `m.server_notice`.
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import AxonWeb.TestHelpers

  alias AxonCore.Repo

  defp make_admin(user_id) do
    Repo.update_all(from(u in "users", where: u.user_id == ^user_id), set: [admin: true])
  end

  test "sends a message that creates the system account and a tagged, invite-only room on first use" do
    admin = register("notice_admin_#{System.unique_integer([:positive])}")
    make_admin(admin.user_id)
    alice = register("notice_alice_#{System.unique_integer([:positive])}")

    conn =
      authed(admin.token)
      |> jp("/_synapse/admin/v1/send_server_notice", %{
        "user_id" => alice.user_id,
        "content" => %{"msgtype" => "m.text", "body" => "your account needs attention"}
      })

    assert conn.status == 200
    event_id = decode(conn)["event_id"]
    assert is_binary(event_id)

    # The recipient is invited, not auto-joined — matches Synapse/Complement
    # (TestServerNotices): they can't see timeline content yet, and can't
    # reject the invite either (see the leave-guard test below), but they
    # must actively join like any other invite.
    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    invite = decode(sync_conn)["rooms"]["invite"]
    assert map_size(invite) == 1
    [{room_id, _}] = Map.to_list(invite)

    authed(alice.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})

    joined_sync = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_data = decode(joined_sync)["rooms"]["join"][room_id]
    events = room_data["timeline"]["events"]

    assert Enum.any?(
             events,
             &(&1["event_id"] == event_id and
                 &1["content"]["body"] == "your account needs attention")
           )

    tags_conn =
      authed(alice.token)
      |> get("/_matrix/client/v3/user/#{alice.user_id}/rooms/#{room_id}/account_data/m.tag")

    assert tags_conn.status == 200
    assert Map.has_key?(decode(tags_conn)["tags"], "m.server_notice")
  end

  test "reuses the same room for a second notice to the same user" do
    admin = register("notice_reuse_admin_#{System.unique_integer([:positive])}")
    make_admin(admin.user_id)
    bob = register("notice_reuse_bob_#{System.unique_integer([:positive])}")

    conn1 =
      authed(admin.token)
      |> jp("/_synapse/admin/v1/send_server_notice", %{
        "user_id" => bob.user_id,
        "content" => %{"msgtype" => "m.text", "body" => "first notice"}
      })

    assert conn1.status == 200
    room_id = decode(authed(bob.token) |> get("/_matrix/client/v3/sync"))["rooms"]["invite"]
    [{room_id, _}] = Map.to_list(room_id)

    authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})

    conn2 =
      authed(admin.token)
      |> jp("/_synapse/admin/v1/send_server_notice", %{
        "user_id" => bob.user_id,
        "content" => %{"msgtype" => "m.text", "body" => "second notice"}
      })

    assert conn2.status == 200

    sync_conn = authed(bob.token) |> get("/_matrix/client/v3/sync")
    join = decode(sync_conn)["rooms"]["join"]
    assert map_size(join) == 1

    [{^room_id, room_data}] = Map.to_list(join)
    bodies = Enum.map(room_data["timeline"]["events"], & &1["content"]["body"])
    assert "first notice" in bodies
    assert "second notice" in bodies
  end

  test "the recipient cannot leave (reject) the invite, but can leave once joined" do
    admin = register("notice_leave_admin_#{System.unique_integer([:positive])}")
    make_admin(admin.user_id)
    carol = register("notice_leave_carol_#{System.unique_integer([:positive])}")

    authed(admin.token)
    |> jp("/_synapse/admin/v1/send_server_notice", %{
      "user_id" => carol.user_id,
      "content" => %{"msgtype" => "m.text", "body" => "hi"}
    })

    invite = decode(authed(carol.token) |> get("/_matrix/client/v3/sync"))["rooms"]["invite"]
    [{room_id, _}] = Map.to_list(invite)

    reject_conn = authed(carol.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/leave", %{})
    assert reject_conn.status == 403
    assert decode(reject_conn)["errcode"] == "M_CANNOT_LEAVE_SERVER_NOTICE_ROOM"

    join_conn = authed(carol.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
    assert join_conn.status == 200

    leave_conn = authed(carol.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/leave", %{})
    assert leave_conn.status == 200
  end

  test "PUT with a txn_id is idempotent" do
    admin = register("notice_txn_admin_#{System.unique_integer([:positive])}")
    make_admin(admin.user_id)
    dave = register("notice_txn_dave_#{System.unique_integer([:positive])}")
    txn = "txn_#{System.unique_integer([:positive])}"

    body = %{"user_id" => dave.user_id, "content" => %{"msgtype" => "m.text", "body" => "hi"}}

    conn1 = authed(admin.token) |> jpu("/_synapse/admin/v1/send_server_notice/#{txn}", body)
    conn2 = authed(admin.token) |> jpu("/_synapse/admin/v1/send_server_notice/#{txn}", body)

    assert conn1.status == 200
    assert conn2.status == 200
    assert decode(conn1)["event_id"] == decode(conn2)["event_id"]
  end

  test "a non-admin cannot send a server notice" do
    alice = register("notice_nonadmin_#{System.unique_integer([:positive])}")
    bob = register("notice_nonadmin_target_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jp("/_synapse/admin/v1/send_server_notice", %{
        "user_id" => bob.user_id,
        "content" => %{"msgtype" => "m.text", "body" => "nope"}
      })

    assert conn.status == 403
  end

  test "404s for an unknown recipient" do
    admin = register("notice_unknown_admin_#{System.unique_integer([:positive])}")
    make_admin(admin.user_id)

    conn =
      authed(admin.token)
      |> jp("/_synapse/admin/v1/send_server_notice", %{
        "user_id" => "@nobody:localhost",
        "content" => %{"msgtype" => "m.text", "body" => "hi"}
      })

    assert conn.status == 404
  end

  test "after leaving the room, the next notice re-invites into the same reused room" do
    admin = register("notice_reinvite_admin_#{System.unique_integer([:positive])}")
    make_admin(admin.user_id)
    erin = register("notice_reinvite_erin_#{System.unique_integer([:positive])}")

    body = %{"user_id" => erin.user_id, "content" => %{"msgtype" => "m.text", "body" => "first"}}
    authed(admin.token) |> jp("/_synapse/admin/v1/send_server_notice", body)

    invite = decode(authed(erin.token) |> get("/_matrix/client/v3/sync"))["rooms"]["invite"]
    [{room_id, _}] = Map.to_list(invite)

    authed(erin.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
    authed(erin.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/leave", %{})

    body2 = %{"user_id" => erin.user_id, "content" => %{"msgtype" => "m.text", "body" => "second"}}
    conn = authed(admin.token) |> jp("/_synapse/admin/v1/send_server_notice", body2)
    assert conn.status == 200

    invite2 = decode(authed(erin.token) |> get("/_matrix/client/v3/sync"))["rooms"]["invite"]
    assert Map.has_key?(invite2, room_id)
  end
end
