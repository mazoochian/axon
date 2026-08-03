defmodule AxonWeb.SyncNotificationsTest do
  @moduledoc """
  Regression tests for classic `/sync`'s `unread_notifications`
  (`notification_count`/`highlight_count`) per joined room — computed via
  the same `AxonWeb.SyncHelpers.unread_counts/2` sliding sync uses (see
  `apps/axon_web/test/sliding_sync_test.exs`'s "notification/highlight
  counts" describe block for that endpoint's equivalent coverage).

  Covers: counts rise on a matching message from another user, stay 0 for
  the sender's own message, a display-name mention increments both counts,
  posting a read receipt clears them, and a muted room's push rule
  (`room`-kind `dont_notify`) suppresses the count entirely.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  defp sync(token, since \\ nil) do
    path =
      if since,
        do: "/_matrix/client/v3/sync?since=#{since}&timeout=0",
        else: "/_matrix/client/v3/sync?timeout=0"

    conn = authed(token) |> get(path)
    assert conn.status == 200
    decode(conn)
  end

  defp unread(body, room_id) do
    get_in(body, ["rooms", "join", room_id, "unread_notifications"])
  end

  test "counts rise on a matching message from another user" do
    alice = register("sn_alice_#{System.unique_integer([:positive])}")
    bob = register("sn_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(bob.token, %{"name" => "Notif", "invite" => [alice.user_id]})

    assert authed(alice.token)
           |> jp("/_matrix/client/v3/join/#{room_id}", %{})
           |> Map.get(:status) ==
             200

    send_event(bob.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "one"})
    send_event(bob.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "two"})

    body = sync(alice.token)
    counts = unread(body, room_id)
    # +1 for the invite-for-me event itself, same accounting sliding sync's
    # equivalent test documents (.m.rule.invite_for_me notifies by default).
    assert counts["notification_count"] == 3
    assert counts["highlight_count"] == 0
  end

  test "the sender's own message never counts toward their own notification_count" do
    alice = register("sn_self_alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"name" => "Self"})

    send_event(alice.token, room_id, "m.room.message", %{
      "msgtype" => "m.text",
      "body" => "talking to myself"
    })

    body = sync(alice.token)
    assert unread(body, room_id)["notification_count"] == 0
    assert unread(body, room_id)["highlight_count"] == 0
  end

  test "a message containing the recipient's display name is a highlight" do
    alice = register("sn_hl_alice_#{System.unique_integer([:positive])}")
    bob = register("sn_hl_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(bob.token, %{"name" => "Highlight", "invite" => [alice.user_id]})

    assert authed(alice.token)
           |> jp("/_matrix/client/v3/join/#{room_id}", %{})
           |> Map.get(:status) ==
             200

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/profile/#{alice.user_id}/displayname", %{
        "displayname" => "Sync Alice"
      })

    assert conn.status == 200

    send_event(bob.token, room_id, "m.room.message", %{
      "msgtype" => "m.text",
      "body" => "hey Sync Alice, check this out"
    })

    body = sync(alice.token)
    counts = unread(body, room_id)
    # +1 for the invite-for-me event, same as the plain-count test above;
    # only the display-name message itself contributes to highlight_count.
    assert counts["notification_count"] == 2
    assert counts["highlight_count"] == 1
  end

  test "posting a read receipt clears the count back to 0" do
    alice = register("sn_ack_alice_#{System.unique_integer([:positive])}")
    bob = register("sn_ack_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(bob.token, %{"name" => "Ack", "invite" => [alice.user_id]})

    assert authed(alice.token)
           |> jp("/_matrix/client/v3/join/#{room_id}", %{})
           |> Map.get(:status) ==
             200

    event_id =
      send_event(bob.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "read me"
      })

    body_before = sync(alice.token)
    assert unread(body_before, room_id)["notification_count"] > 0

    read_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read/#{event_id}", %{})

    assert read_conn.status == 200

    body_after = sync(alice.token, body_before["next_batch"])
    assert unread(body_after, room_id)["notification_count"] == 0
    assert unread(body_after, room_id)["highlight_count"] == 0
  end

  test "a muted room's push rule suppresses the count entirely" do
    alice = register("sn_mute_alice_#{System.unique_integer([:positive])}")
    bob = register("sn_mute_bob_#{System.unique_integer([:positive])}")
    # Deliberately a direct /join (not an invite): alice must not have
    # received the always-notifying `.m.rule.invite_for_me` override
    # notification along the way, since that's an "override"-kind rule
    # that matches and halts *before* a "room"-kind mute rule ever gets
    # evaluated — muting a room can't retroactively suppress an invite
    # notification that already fired via a higher-priority rule kind.
    room_id = create_room(bob.token, %{"name" => "Mute", "preset" => "public_chat"})

    assert authed(alice.token)
           |> jp("/_matrix/client/v3/join/#{room_id}", %{})
           |> Map.get(:status) ==
             200

    mute_conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/pushrules/global/room/#{room_id}", %{
        "actions" => ["dont_notify"]
      })

    assert mute_conn.status == 200

    send_event(bob.token, room_id, "m.room.message", %{
      "msgtype" => "m.text",
      "body" => "should not bump the badge"
    })

    body = sync(alice.token)
    counts = unread(body, room_id)
    assert counts["notification_count"] == 0
    assert counts["highlight_count"] == 0
  end
end
