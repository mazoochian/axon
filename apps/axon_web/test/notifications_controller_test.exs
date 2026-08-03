defmodule AxonWeb.NotificationsControllerTest do
  @moduledoc """
  Regression tests for `GET /_matrix/client/v3/notifications`
  (`AxonWeb.NotificationsController`), backed by the `AxonPush.Notifications`
  ledger `AxonPush.Dispatcher` writes to (fire-and-forget, so these tests
  poll briefly for the async write to land — same pattern as
  `apps/axon_web/test/e2e/push_pipeline_flow_test.exs`'s `wait_for_delivery`).

  Covers: entry shape (actions/event/profile_tag/read/room_id/ts), the
  sender's own event never appearing, a muted room never appearing,
  `only=highlight` filtering, `read` reflecting the current read receipt,
  and `from`/`limit` pagination via `next_token`.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  defp notifications(token, query \\ "") do
    path = "/_matrix/client/v3/notifications"
    path = if query == "", do: path, else: "#{path}?#{query}"
    conn = authed(token) |> get(path)
    assert conn.status == 200
    decode(conn)
  end

  defp wait_for_notifications(token, min_count \\ 1, retries \\ 50) do
    body = notifications(token)

    cond do
      length(body["notifications"]) >= min_count ->
        body

      retries > 0 ->
        Process.sleep(20)
        wait_for_notifications(token, min_count, retries - 1)

      true ->
        body
    end
  end

  test "a matching event from another user shows up with the expected entry shape" do
    alice = register("nc_alice_#{System.unique_integer([:positive])}")
    bob = register("nc_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(bob.token, %{"name" => "Shape", "preset" => "public_chat"})

    assert authed(alice.token)
           |> jp("/_matrix/client/v3/join/#{room_id}", %{})
           |> Map.get(:status) ==
             200

    event_id =
      send_event(bob.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "hello alice"
      })

    body = wait_for_notifications(alice.token)
    [entry] = body["notifications"]

    assert entry["room_id"] == room_id
    assert entry["event"]["event_id"] == event_id
    assert entry["event"]["sender"] == bob.user_id
    assert is_list(entry["actions"])
    assert Enum.any?(entry["actions"], &(&1 == "notify"))
    assert Map.has_key?(entry, "profile_tag")
    assert is_boolean(entry["read"])
    assert entry["read"] == false
    assert is_integer(entry["ts"])
  end

  test "the sender never sees their own event in their own notifications" do
    alice = register("nc_self_alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"name" => "Self"})

    send_event(alice.token, room_id, "m.room.message", %{
      "msgtype" => "m.text",
      "body" => "talking to myself"
    })

    Process.sleep(150)
    body = notifications(alice.token)
    assert body["notifications"] == []
  end

  test "a muted room's messages never appear" do
    alice = register("nc_mute_alice_#{System.unique_integer([:positive])}")
    bob = register("nc_mute_bob_#{System.unique_integer([:positive])}")
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
      "body" => "should never show up"
    })

    Process.sleep(150)
    body = notifications(alice.token)
    assert body["notifications"] == []
  end

  test "reading the event marks the notification read: true" do
    alice = register("nc_read_alice_#{System.unique_integer([:positive])}")
    bob = register("nc_read_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(bob.token, %{"name" => "Read", "preset" => "public_chat"})

    assert authed(alice.token)
           |> jp("/_matrix/client/v3/join/#{room_id}", %{})
           |> Map.get(:status) ==
             200

    event_id =
      send_event(bob.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "mark me read"
      })

    body_before = wait_for_notifications(alice.token)
    assert [%{"read" => false}] = body_before["notifications"]

    receipt_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read/#{event_id}", %{})

    assert receipt_conn.status == 200

    body_after = notifications(alice.token)
    assert [%{"read" => true}] = body_after["notifications"]
  end

  test "only=highlight filters to just highlighted notifications" do
    alice = register("nc_hl_alice_#{System.unique_integer([:positive])}")
    bob = register("nc_hl_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(bob.token, %{"name" => "Highlight", "preset" => "public_chat"})

    assert authed(alice.token)
           |> jp("/_matrix/client/v3/join/#{room_id}", %{})
           |> Map.get(:status) ==
             200

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/profile/#{alice.user_id}/displayname", %{
        "displayname" => "Notif Alice"
      })

    assert conn.status == 200

    plain_id =
      send_event(bob.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "plain message"
      })

    hl_id =
      send_event(bob.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "hey Notif Alice, look at this"
      })

    body = wait_for_notifications(alice.token, 2)
    assert length(body["notifications"]) == 2

    only_hl = notifications(alice.token, "only=highlight")
    assert [entry] = only_hl["notifications"]
    assert entry["event"]["event_id"] == hl_id
    refute entry["event"]["event_id"] == plain_id
  end

  test "limit/from paginate newest-first with no overlap" do
    alice = register("nc_page_alice_#{System.unique_integer([:positive])}")
    bob = register("nc_page_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(bob.token, %{"name" => "Page", "preset" => "public_chat"})

    assert authed(alice.token)
           |> jp("/_matrix/client/v3/join/#{room_id}", %{})
           |> Map.get(:status) ==
             200

    for i <- 1..5 do
      send_event(bob.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "msg #{i}"
      })
    end

    wait_for_notifications(alice.token, 5)

    page1 = notifications(alice.token, "limit=2")
    assert length(page1["notifications"]) == 2
    assert page1["next_token"]

    page2 = notifications(alice.token, "limit=2&from=#{page1["next_token"]}")
    assert length(page2["notifications"]) == 2

    page1_ids = Enum.map(page1["notifications"], & &1["event"]["event_id"])
    page2_ids = Enum.map(page2["notifications"], & &1["event"]["event_id"])
    assert MapSet.disjoint?(MapSet.new(page1_ids), MapSet.new(page2_ids))
  end
end
