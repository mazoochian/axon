defmodule AxonWeb.ServerNoticesTest do
  @moduledoc """
  Regression tests for Phase 14's server notices: an admin-triggered
  message from a lazily-provisioned system account (`@server-notices:...`)
  into an auto-created, reused-per-recipient room tagged `m.server_notice`.
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import AxonWeb.TestHelpers

  alias AxonCore.Repo

  defp make_admin(user_id) do
    Repo.update_all(from(u in "users", where: u.user_id == ^user_id), set: [admin: true])
  end

  test "sends a message that creates the system account and a tagged room on first use" do
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

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    body = decode(sync_conn)
    join = body["rooms"]["join"]
    assert map_size(join) == 1
    [{room_id, room_data}] = Map.to_list(join)

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

    conn2 =
      authed(admin.token)
      |> jp("/_synapse/admin/v1/send_server_notice", %{
        "user_id" => bob.user_id,
        "content" => %{"msgtype" => "m.text", "body" => "second notice"}
      })

    assert conn1.status == 200
    assert conn2.status == 200

    sync_conn = authed(bob.token) |> get("/_matrix/client/v3/sync")
    join = decode(sync_conn)["rooms"]["join"]
    assert map_size(join) == 1

    [{_room_id, room_data}] = Map.to_list(join)
    bodies = Enum.map(room_data["timeline"]["events"], & &1["content"]["body"])
    assert "first notice" in bodies
    assert "second notice" in bodies
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
end
