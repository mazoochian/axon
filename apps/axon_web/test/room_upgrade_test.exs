defmodule AxonWeb.RoomUpgradeTest do
  @moduledoc """
  Phase 5 — room version upgrades: POST /rooms/:roomId/upgrade tombstones
  the old room and creates a new one on the requested version, carrying
  over power_levels/join_rules/name/etc. and a predecessor link.
  """

  use AxonWeb.ConnCase, async: false

  defp register(username) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/register",
        Jason.encode!(%{
          "username" => username,
          "password" => "Test1234!",
          "kind" => "user",
          "auth" => %{"type" => "m.login.dummy"}
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    %{token: body["access_token"], user_id: body["user_id"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp jp(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp jput(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> put(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token, opts \\ %{}) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", opts)
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp get_state_event(token, room_id, type) do
    conn = authed(token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/#{type}?format=event")
    {conn.status, decode(conn)}
  end

  test "upgrade tombstones the old room and creates a new one with copied state" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"name" => "Old Room", "preset" => "public_chat"})

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/upgrade", %{"new_version" => "10"})

    assert conn.status == 200
    new_room_id = decode(conn)["replacement_room"]
    assert new_room_id != room_id

    # Old room got tombstoned pointing at the new room.
    {200, tombstone} = get_state_event(alice.token, room_id, "m.room.tombstone")
    assert tombstone["content"]["replacement_room"] == new_room_id

    # New room's create event references the old room and the new version.
    {200, create_event} = get_state_event(alice.token, new_room_id, "m.room.create")
    assert create_event["content"]["room_version"] == "10"
    assert create_event["content"]["predecessor"]["room_id"] == room_id
    assert create_event["content"]["predecessor"]["event_id"] == tombstone["event_id"]

    # Name and join_rules carried over.
    {200, name_event} = get_state_event(alice.token, new_room_id, "m.room.name")
    assert name_event["content"]["name"] == "Old Room"

    {200, join_rules} = get_state_event(alice.token, new_room_id, "m.room.join_rules")
    assert join_rules["content"]["join_rule"] == "public"
  end

  test "observing an upgrade copies each joined local user's room push rule" do
    alice = register("alice_push_upgrade_#{System.unique_integer([:positive])}")
    bob = register("bob_push_upgrade_#{System.unique_integer([:positive])}")
    outsider = register("outsider_push_upgrade_#{System.unique_integer([:positive])}")
    old_room_id = create_room(alice.token, %{"preset" => "public_chat"})
    unrelated_room_id = create_room(alice.token)

    assert authed(bob.token)
           |> jp("/_matrix/client/v3/rooms/#{old_room_id}/join", %{})
           |> Map.get(:status) == 200

    for user <- [alice, bob, outsider] do
      assert authed(user.token)
             |> jput("/_matrix/client/v3/pushrules/global/room/#{URI.encode(old_room_id)}", %{
               "actions" => ["dont_notify", %{"set_tweak" => "highlight", "value" => false}]
             })
             |> Map.get(:status) == 200
    end

    assert authed(bob.token)
           |> jput(
             "/_matrix/client/v3/pushrules/global/room/#{URI.encode(old_room_id)}/enabled",
             %{"enabled" => false}
           )
           |> Map.get(:status) == 200

    assert authed(alice.token)
           |> jput("/_matrix/client/v3/pushrules/global/room/#{URI.encode(unrelated_room_id)}", %{
             "actions" => ["notify"]
           })
           |> Map.get(:status) == 200

    upgrade =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{old_room_id}/upgrade", %{"new_version" => "10"})

    assert upgrade.status == 200
    new_room_id = decode(upgrade)["replacement_room"]

    alice_rules = authed(alice.token) |> get("/_matrix/client/v3/pushrules/") |> decode()
    bob_rules = authed(bob.token) |> get("/_matrix/client/v3/pushrules/") |> decode()
    outsider_rules = authed(outsider.token) |> get("/_matrix/client/v3/pushrules/") |> decode()

    alice_by_id = Map.new(alice_rules["global"]["room"], &{&1["rule_id"], &1})
    bob_by_id = Map.new(bob_rules["global"]["room"], &{&1["rule_id"], &1})
    outsider_ids = Enum.map(outsider_rules["global"]["room"], & &1["rule_id"])

    assert Map.keys(alice_by_id) |> Enum.sort() ==
             Enum.sort([old_room_id, new_room_id, unrelated_room_id])

    assert Map.take(alice_by_id[new_room_id], ["actions", "default", "enabled"]) ==
             Map.take(alice_by_id[old_room_id], ["actions", "default", "enabled"])

    assert Map.keys(bob_by_id) |> Enum.sort() == Enum.sort([old_room_id, new_room_id])
    assert bob_by_id[new_room_id]["enabled"] == false
    assert bob_by_id[new_room_id]["actions"] == bob_by_id[old_room_id]["actions"]
    assert outsider_ids == [old_room_id]
  end

  test "upgrade rejects a non-member" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)

    conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/upgrade", %{"new_version" => "10"})

    assert conn.status == 403
    assert decode(conn)["errcode"] == "M_FORBIDDEN"
  end

  test "upgrade rejects a member without tombstone power" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    join_conn = authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
    assert join_conn.status == 200

    conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/upgrade", %{"new_version" => "10"})

    assert conn.status == 403
    assert decode(conn)["errcode"] == "M_FORBIDDEN"
  end

  test "upgrade rejects an unsupported room version" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/upgrade", %{"new_version" => "999"})

    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_UNSUPPORTED_ROOM_VERSION"
  end
end
