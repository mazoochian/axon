defmodule AxonWeb.AdminControllerTest do
  @moduledoc """
  Regression tests for Phase 13's admin API (`/_synapse/admin/v1/...`):
  the `RequireAdmin` gate, user management (list/get/deactivate/shadow-ban),
  room management (list/get/purge), media quarantine, and the report queue.
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import AxonWeb.TestHelpers

  alias AxonCore.Repo

  defp make_admin(user_id) do
    Repo.update_all(from(u in "users", where: u.user_id == ^user_id), set: [admin: true])
  end

  describe "RequireAdmin gate" do
    test "a non-admin user is rejected with 403" do
      alice = register("admin_gate_#{System.unique_integer([:positive])}")
      conn = authed(alice.token) |> get("/_synapse/admin/v1/users")
      assert conn.status == 403
      assert decode(conn)["errcode"] == "M_FORBIDDEN"
    end

    test "an unauthenticated request is rejected" do
      conn = build_conn() |> get("/_synapse/admin/v1/users")
      assert conn.status == 401
    end

    test "an admin user can access admin endpoints" do
      admin = register("admin_gate_ok_#{System.unique_integer([:positive])}")
      make_admin(admin.user_id)
      conn = authed(admin.token) |> get("/_synapse/admin/v1/users")
      assert conn.status == 200
    end
  end

  describe "user management" do
    setup do
      admin = register("admin_users_#{System.unique_integer([:positive])}")
      make_admin(admin.user_id)
      %{admin: admin}
    end

    test "list_users returns paginated users including the requester", %{admin: admin} do
      conn = authed(admin.token) |> get("/_synapse/admin/v1/users")
      assert conn.status == 200
      body = decode(conn)
      assert is_integer(body["total"])
      assert Enum.any?(body["users"], &(&1["name"] == admin.user_id))
    end

    test "get_user returns a single user's details", %{admin: admin} do
      alice = register("admin_getuser_#{System.unique_integer([:positive])}")
      conn = authed(admin.token) |> get("/_synapse/admin/v1/users/#{alice.user_id}")
      assert conn.status == 200
      assert decode(conn)["name"] == alice.user_id
    end

    test "get_user 404s for an unknown user", %{admin: admin} do
      conn = authed(admin.token) |> get("/_synapse/admin/v1/users/@nobody:localhost")
      assert conn.status == 404
    end

    test "deactivate_user deactivates the target and invalidates their tokens", %{admin: admin} do
      alice = register("admin_deact_#{System.unique_integer([:positive])}")

      conn = authed(admin.token) |> jp("/_synapse/admin/v1/deactivate/#{alice.user_id}", %{})
      assert conn.status == 200

      whoami_conn = authed(alice.token) |> get("/_matrix/client/v3/account/whoami")
      assert whoami_conn.status == 401
    end

    test "shadow_ban and unshadow_ban toggle the flag", %{admin: admin} do
      alice = register("admin_sb_#{System.unique_integer([:positive])}")

      assert authed(admin.token)
             |> jp("/_synapse/admin/v1/users/#{alice.user_id}/shadow_ban", %{})
             |> Map.get(:status) == 200

      get_conn = authed(admin.token) |> get("/_synapse/admin/v1/users/#{alice.user_id}")
      assert decode(get_conn)["shadow_banned"] == true

      assert authed(admin.token)
             |> delete("/_synapse/admin/v1/users/#{alice.user_id}/shadow_ban")
             |> Map.get(:status) == 200

      get_conn2 = authed(admin.token) |> get("/_synapse/admin/v1/users/#{alice.user_id}")
      assert decode(get_conn2)["shadow_banned"] == false
    end
  end

  describe "room management" do
    setup do
      admin = register("admin_rooms_#{System.unique_integer([:positive])}")
      make_admin(admin.user_id)
      %{admin: admin}
    end

    test "list_rooms and get_room return room details", %{admin: admin} do
      alice = register("admin_room_owner_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      list_conn = authed(admin.token) |> get("/_synapse/admin/v1/rooms")
      assert list_conn.status == 200
      assert Enum.any?(decode(list_conn)["rooms"], &(&1["room_id"] == room_id))

      get_conn = authed(admin.token) |> get("/_synapse/admin/v1/rooms/#{room_id}")
      assert get_conn.status == 200
      assert decode(get_conn)["creator"] == alice.user_id
    end

    test "purge_room deletes room content and blocks future joins", %{admin: admin} do
      alice = register("admin_purge_owner_#{System.unique_integer([:positive])}")
      bob = register("admin_purge_joiner_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      purge_conn = authed(admin.token) |> delete("/_synapse/admin/v1/rooms/#{room_id}")
      assert purge_conn.status == 200
      assert decode(purge_conn)["status"] == "complete"

      join_conn = authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
      assert join_conn.status == 403
      assert decode(join_conn)["errcode"] == "M_FORBIDDEN"
    end

    test "purge_room 404s for an unknown room", %{admin: admin} do
      conn = authed(admin.token) |> delete("/_synapse/admin/v1/rooms/!nonexistent:localhost")
      assert conn.status == 404
    end
  end

  describe "media quarantine" do
    test "quarantining media makes it 404 on download, unquarantining restores it" do
      admin = register("admin_media_#{System.unique_integer([:positive])}")
      make_admin(admin.user_id)

      upload_conn =
        authed(admin.token)
        |> put_req_header("content-type", "text/plain")
        |> post("/_matrix/media/v3/upload", "hello world")

      assert upload_conn.status == 200
      "mxc://" <> rest = decode(upload_conn)["content_uri"]
      [server, media_id] = String.split(rest, "/", parts: 2)

      download_conn = build_conn() |> get("/_matrix/media/v3/download/#{server}/#{media_id}")
      assert download_conn.status == 200

      q_conn =
        authed(admin.token)
        |> jp("/_synapse/admin/v1/media/quarantine/#{server}/#{media_id}", %{})

      assert q_conn.status == 200

      after_q_conn = build_conn() |> get("/_matrix/media/v3/download/#{server}/#{media_id}")
      assert after_q_conn.status == 404

      uq_conn =
        authed(admin.token)
        |> delete("/_synapse/admin/v1/media/quarantine/#{server}/#{media_id}")

      assert uq_conn.status == 200

      after_uq_conn = build_conn() |> get("/_matrix/media/v3/download/#{server}/#{media_id}")
      assert after_uq_conn.status == 200
    end
  end

  describe "report queue" do
    test "list_reports surfaces reports collected via the client report endpoints" do
      admin = register("admin_reports_#{System.unique_integer([:positive])}")
      make_admin(admin.user_id)
      alice = register("admin_reports_alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      event_id =
        send_event(alice.token, room_id, "m.room.message", %{
          "msgtype" => "m.text",
          "body" => "spam"
        })

      report_conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/report/#{event_id}", %{"reason" => "spam"})

      assert report_conn.status == 200

      list_conn = authed(admin.token) |> get("/_synapse/admin/v1/event_reports")
      assert list_conn.status == 200
      body = decode(list_conn)

      assert Enum.any?(
               body["event_reports"],
               &(&1["event_id"] == event_id and &1["reason"] == "spam")
             )
    end
  end
end
