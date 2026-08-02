defmodule AxonWeb.SlidingSyncTest do
  @moduledoc """
  Regression tests for Phase 10 (sliding sync, MSC4186):
  `POST /_matrix/client/unstable/org.matrix.msc4186/sync`.

  Covers the pragmatic subset actually implemented: recency-sorted lists
  with ranges, room_subscriptions, required_state resolution (concrete
  types, `$LAZY`, `$ME`), filters (is_dm/is_encrypted), the long-poll
  wake-up path (reusing AxonSync.Manager, so the Phase 8 fix applies here
  too), and each extension (to_device/e2ee/account_data/receipts/typing).
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  @path "/_matrix/client/unstable/org.matrix.msc4186/sync"

  defp sliding_sync(token, body, opts \\ []) do
    query =
      [opts[:pos] && "pos=#{opts[:pos]}", opts[:timeout] && "timeout=#{opts[:timeout]}"]
      |> Enum.filter(& &1)
      |> Enum.join("&")

    path = if query == "", do: @path, else: "#{@path}?#{query}"
    conn = authed(token) |> jp(path, body)
    assert conn.status == 200
    decode(conn)
  end

  defp send_state(token, room_id, type, state_key, content) do
    conn =
      authed(token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/#{type}/#{state_key}", content)

    assert conn.status == 200
    decode(conn)["event_id"]
  end

  defp join_room(token, room_id) do
    conn = authed(token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
    assert conn.status == 200
  end

  defp basic_list(range \\ [0, 9]) do
    %{"ranges" => [range], "sort" => ["by_recency"], "timeline_limit" => 5}
  end

  describe "lists" do
    test "initial sync returns joined rooms sorted by recency, most recent first" do
      alice = register("ss_alice_#{System.unique_integer([:positive])}")
      room_a = create_room(alice.token, %{"name" => "A"})
      room_b = create_room(alice.token, %{"name" => "B"})

      # Bump A's recency above B by sending a fresh message in it.
      send_event(alice.token, room_a, "m.room.message", %{"msgtype" => "m.text", "body" => "hi"})

      body = sliding_sync(alice.token, %{"lists" => %{"main" => basic_list()}})

      assert %{"count" => 2, "ops" => [%{"op" => "SYNC", "range" => [0, 9], "room_ids" => ids}]} =
               body["lists"]["main"]

      assert ids == [room_a, room_b]
      assert Map.has_key?(body["rooms"], room_a)
      assert Map.has_key?(body["rooms"], room_b)
      assert body["rooms"][room_a]["initial"] == true
      assert is_binary(body["pos"])
    end

    test "ranges page the sorted list" do
      alice = register("ss_ranges_#{System.unique_integer([:positive])}")
      rooms = for i <- 1..3, do: create_room(alice.token, %{"name" => "R#{i}"})
      [_r1, r2, r3] = rooms

      body = sliding_sync(alice.token, %{"lists" => %{"main" => basic_list([0, 0])}})

      # Most recently created room (r3) sorts first.
      assert %{"ops" => [%{"room_ids" => [only_id]}]} = body["lists"]["main"]
      assert only_id == r3
      refute Map.has_key?(body["rooms"], r2)
    end

    test "is_encrypted filter narrows the list" do
      alice = register("ss_enc_#{System.unique_integer([:positive])}")
      plain = create_room(alice.token, %{"name" => "plain"})
      encrypted = create_room(alice.token, %{"name" => "enc"})

      send_state(alice.token, encrypted, "m.room.encryption", "", %{
        "algorithm" => "m.megolm.v1.aes-sha2"
      })

      list_cfg = Map.put(basic_list(), "filters", %{"is_encrypted" => true})
      body = sliding_sync(alice.token, %{"lists" => %{"main" => list_cfg}})

      assert %{"ops" => [%{"room_ids" => ids}]} = body["lists"]["main"]
      assert ids == [encrypted]
      refute plain in ids
    end

    test "is_dm filter narrows the list" do
      alice = register("ss_dm_#{System.unique_integer([:positive])}")
      bob = register("ss_dm_bob_#{System.unique_integer([:positive])}")
      dm_room = create_room(alice.token, %{"name" => "dm", "invite" => [bob.user_id]})
      other = create_room(alice.token, %{"name" => "other"})

      conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/user/#{alice.user_id}/account_data/m.direct", %{
          bob.user_id => [dm_room]
        })

      assert conn.status == 200

      list_cfg = Map.put(basic_list(), "filters", %{"is_dm" => true})
      body = sliding_sync(alice.token, %{"lists" => %{"main" => list_cfg}})

      assert %{"ops" => [%{"room_ids" => ids}]} = body["lists"]["main"]
      assert ids == [dm_room]
      refute other in ids
    end
  end

  describe "required_state resolution" do
    test "concrete [type, state_key] pairs resolve exactly" do
      alice = register("ss_state_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"name" => "Original"})
      send_state(alice.token, room_id, "m.room.topic", "", %{"topic" => "hello"})

      list_cfg =
        basic_list()
        |> Map.put("required_state", [["m.room.topic", ""], ["m.room.name", ""]])

      body = sliding_sync(alice.token, %{"lists" => %{"main" => list_cfg}})
      types = body["rooms"][room_id]["required_state"] |> Enum.map(& &1["type"]) |> Enum.sort()
      assert types == ["m.room.name", "m.room.topic"]
    end

    test "$LAZY only includes member events for timeline senders (plus self)" do
      alice = register("ss_lazy_alice_#{System.unique_integer([:positive])}")
      bob = register("ss_lazy_bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"name" => "Lazy", "invite" => [bob.user_id]})
      join_room(bob.token, room_id)
      send_event(bob.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "hey"})

      list_cfg =
        basic_list()
        |> Map.put("required_state", [["m.room.member", "$LAZY"]])
        |> Map.put("timeline_limit", 1)

      body = sliding_sync(alice.token, %{"lists" => %{"main" => list_cfg}})

      member_keys =
        body["rooms"][room_id]["required_state"]
        |> Enum.filter(&(&1["type"] == "m.room.member"))
        |> Enum.map(& &1["state_key"])
        |> Enum.sort()

      # bob sent the only timeline event in range; alice is always included (self).
      assert member_keys == Enum.sort([alice.user_id, bob.user_id])
    end

    test "$ME resolves to the requesting user's own state" do
      alice = register("ss_me_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"name" => "Me"})

      list_cfg = Map.put(basic_list(), "required_state", [["m.room.member", "$ME"]])
      body = sliding_sync(alice.token, %{"lists" => %{"main" => list_cfg}})

      assert [%{"type" => "m.room.member", "state_key" => me}] =
               body["rooms"][room_id]["required_state"]

      assert me == alice.user_id
    end
  end

  describe "room_subscriptions" do
    test "a subscribed room is included even when its list range excludes it" do
      alice = register("ss_sub_#{System.unique_integer([:positive])}")
      rooms = for i <- 1..3, do: create_room(alice.token, %{"name" => "S#{i}"})
      [r1, _r2, _r3] = rooms

      body =
        sliding_sync(alice.token, %{
          "lists" => %{"main" => basic_list([0, 0])},
          "room_subscriptions" => %{r1 => %{"timeline_limit" => 3}}
        })

      assert %{"ops" => [%{"room_ids" => in_range}]} = body["lists"]["main"]
      refute r1 in in_range
      assert Map.has_key?(body["rooms"], r1)
    end
  end

  describe "invited/knocked room visibility" do
    test "an invited room appears with invite_state instead of a timeline" do
      alice = register("ss_inv_alice_#{System.unique_integer([:positive])}")
      bob = register("ss_inv_bob_#{System.unique_integer([:positive])}")
      room_id = create_room(bob.token, %{"name" => "Invited", "invite" => [alice.user_id]})

      body = sliding_sync(alice.token, %{"lists" => %{"main" => basic_list()}})

      assert %{"ops" => [%{"room_ids" => ids}]} = body["lists"]["main"]
      assert room_id in ids

      entry = body["rooms"][room_id]
      assert %{"invite_state" => %{"events" => events}} = entry
      refute Map.has_key?(entry, "timeline")
      refute Map.has_key?(entry, "notification_count")

      member_event =
        Enum.find(events, &(&1["type"] == "m.room.member" and &1["state_key"] == alice.user_id))

      assert member_event["content"]["membership"] == "invite"
    end

    test "a knocked room appears with knock_state instead of a timeline" do
      alice = register("ss_knock_alice_#{System.unique_integer([:positive])}")
      bob = register("ss_knock_bob_#{System.unique_integer([:positive])}")

      room_id =
        create_room(bob.token, %{
          "name" => "Knockable",
          "initial_state" => [
            %{"type" => "m.room.join_rules", "content" => %{"join_rule" => "knock"}}
          ]
        })

      conn = authed(alice.token) |> jp("/_matrix/client/v3/knock/#{room_id}", %{})
      assert conn.status == 200

      body = sliding_sync(alice.token, %{"lists" => %{"main" => basic_list()}})

      assert %{"ops" => [%{"room_ids" => ids}]} = body["lists"]["main"]
      assert room_id in ids

      entry = body["rooms"][room_id]
      assert %{"knock_state" => %{"events" => events}} = entry
      refute Map.has_key?(entry, "timeline")
      assert Enum.any?(events, &(&1["type"] == "m.room.join_rules"))
    end

    test "an invited room can still be reached via room_subscriptions" do
      alice = register("ss_inv_sub_alice_#{System.unique_integer([:positive])}")
      bob = register("ss_inv_sub_bob_#{System.unique_integer([:positive])}")
      room_id = create_room(bob.token, %{"name" => "InvitedSub", "invite" => [alice.user_id]})

      body =
        sliding_sync(alice.token, %{
          "lists" => %{},
          "room_subscriptions" => %{room_id => %{"timeline_limit" => 5}}
        })

      assert %{"invite_state" => _} = body["rooms"][room_id]
    end
  end

  describe "notification/highlight counts" do
    defp read_receipt(token, room_id, event_id) do
      conn =
        authed(token) |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read/#{event_id}", %{})

      assert conn.status == 200
    end

    test "counts unread messages from another user since the last read receipt" do
      alice = register("ss_notif_alice_#{System.unique_integer([:positive])}")
      bob = register("ss_notif_bob_#{System.unique_integer([:positive])}")
      room_id = create_room(bob.token, %{"name" => "Notif", "invite" => [alice.user_id]})
      join_room(alice.token, room_id)

      send_event(bob.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "one"})
      send_event(bob.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "two"})

      body = sliding_sync(alice.token, %{"lists" => %{"main" => basic_list()}})
      # +1 for the invite-for-me event itself — .m.rule.invite_for_me notifies
      # (without highlighting) by default, same as any other unread notification.
      assert body["rooms"][room_id]["notification_count"] == 3
      assert body["rooms"][room_id]["highlight_count"] == 0
    end

    test "advancing the read receipt drops the count back to 0" do
      alice = register("ss_notif_ack_alice_#{System.unique_integer([:positive])}")
      bob = register("ss_notif_ack_bob_#{System.unique_integer([:positive])}")
      room_id = create_room(bob.token, %{"name" => "Ack", "invite" => [alice.user_id]})
      join_room(alice.token, room_id)

      event_id =
        send_event(bob.token, room_id, "m.room.message", %{
          "msgtype" => "m.text",
          "body" => "read me"
        })

      read_receipt(alice.token, room_id, event_id)

      body = sliding_sync(alice.token, %{"lists" => %{"main" => basic_list()}})
      assert body["rooms"][room_id]["notification_count"] == 0
    end

    test "a message containing the recipient's display name is a highlight" do
      alice = register("ss_notif_hl_alice_#{System.unique_integer([:positive])}")
      bob = register("ss_notif_hl_bob_#{System.unique_integer([:positive])}")
      room_id = create_room(bob.token, %{"name" => "Highlight", "invite" => [alice.user_id]})
      join_room(alice.token, room_id)

      conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/profile/#{alice.user_id}/displayname", %{
          "displayname" => "Wonderland Alice"
        })

      assert conn.status == 200

      send_event(bob.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "hey Wonderland Alice, check this out"
      })

      body = sliding_sync(alice.token, %{"lists" => %{"main" => basic_list()}})
      # +1 for the invite-for-me event, same as above; only the display-name
      # message itself contributes to highlight_count.
      assert body["rooms"][room_id]["notification_count"] == 2
      assert body["rooms"][room_id]["highlight_count"] == 1
    end

    test "the sender's own messages never count toward their own notification_count" do
      alice = register("ss_notif_self_alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"name" => "Self"})

      send_event(alice.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "talking to myself"
      })

      body = sliding_sync(alice.token, %{"lists" => %{"main" => basic_list()}})
      assert body["rooms"][room_id]["notification_count"] == 0
    end
  end

  describe "long-poll wake-up" do
    test "a nonzero timeout returns as soon as a message arrives in a visible room" do
      alice = register("ss_poll_alice_#{System.unique_integer([:positive])}")
      bob = register("ss_poll_bob_#{System.unique_integer([:positive])}")
      room_id = create_room(bob.token, %{"name" => "Poll", "invite" => [alice.user_id]})
      join_room(alice.token, room_id)

      list_body = %{"lists" => %{"main" => basic_list()}}
      pos = sliding_sync(alice.token, list_body)["pos"]

      task =
        Task.async(fn ->
          started_at = System.monotonic_time(:millisecond)
          body = sliding_sync(alice.token, list_body, pos: pos, timeout: 5_000)
          {body, System.monotonic_time(:millisecond) - started_at}
        end)

      Process.sleep(200)

      send_event(bob.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "wake up"
      })

      {body, elapsed_ms} = Task.await(task, 6_000)
      assert elapsed_ms < 2_000

      event = Enum.find(body["rooms"][room_id]["timeline"], &(&1["type"] == "m.room.message"))
      assert event["content"]["body"] == "wake up"
    end
  end

  describe "extensions" do
    test "to_device drains pending messages" do
      alice = register("ss_ext_alice_#{System.unique_integer([:positive])}")
      bob = register("ss_ext_bob_#{System.unique_integer([:positive])}")

      conn =
        authed(alice.token)
        |> jpu(
          "/_matrix/client/v3/sendToDevice/m.room_key/txn_#{System.unique_integer([:positive])}",
          %{
            "messages" => %{bob.user_id => %{bob.device_id => %{"session_key" => "s3kr3t"}}}
          }
        )

      assert conn.status == 200

      body =
        sliding_sync(bob.token, %{
          "lists" => %{},
          "extensions" => %{"to_device" => %{"enabled" => true}}
        })

      assert [event] = body["extensions"]["to_device"]["events"]
      assert event["sender"] == alice.user_id
      assert event["content"]["session_key"] == "s3kr3t"
    end

    test "e2ee reports device_lists.changed on a newly shared room" do
      alice = register("ss_ext_dl_alice_#{System.unique_integer([:positive])}")
      bob = register("ss_ext_dl_bob_#{System.unique_integer([:positive])}")

      pos =
        sliding_sync(alice.token, %{
          "lists" => %{},
          "extensions" => %{"e2ee" => %{"enabled" => true}}
        })["pos"]

      room_id = create_room(alice.token, %{"name" => "DL", "invite" => [bob.user_id]})
      join_room(bob.token, room_id)

      body =
        sliding_sync(
          alice.token,
          %{"lists" => %{}, "extensions" => %{"e2ee" => %{"enabled" => true}}},
          pos: pos
        )

      assert bob.user_id in body["extensions"]["e2ee"]["device_lists"]["changed"]
    end

    test "account_data reports global and per-room account data for visible rooms" do
      alice = register("ss_ext_ad_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"name" => "AD"})

      conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/user/#{alice.user_id}/rooms/#{room_id}/account_data/m.tag", %{
          "tags" => %{"m.favourite" => %{}}
        })

      assert conn.status == 200

      body =
        sliding_sync(alice.token, %{
          "lists" => %{"main" => basic_list()},
          "extensions" => %{"account_data" => %{"enabled" => true}}
        })

      assert [%{"type" => "m.tag"}] = body["extensions"]["account_data"]["rooms"][room_id]
    end

    test "receipts and typing extensions surface per-room ephemeral state" do
      alice = register("ss_ext_eph_alice_#{System.unique_integer([:positive])}")
      bob = register("ss_ext_eph_bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"name" => "Eph", "invite" => [bob.user_id]})
      join_room(bob.token, room_id)

      event_id =
        send_event(alice.token, room_id, "m.room.message", %{
          "msgtype" => "m.text",
          "body" => "hi"
        })

      conn =
        authed(bob.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read/#{event_id}", %{})

      assert conn.status == 200

      conn =
        authed(bob.token)
        |> jpu("/_matrix/client/v3/rooms/#{room_id}/typing/#{bob.user_id}", %{
          "typing" => true,
          "timeout" => 30_000
        })

      assert conn.status == 200

      body =
        sliding_sync(alice.token, %{
          "lists" => %{"main" => basic_list()},
          "extensions" => %{
            "receipts" => %{"enabled" => true},
            "typing" => %{"enabled" => true}
          }
        })

      receipt_event = body["extensions"]["receipts"]["rooms"][room_id]
      assert get_in(receipt_event, ["content", event_id, "m.read", bob.user_id]) != nil

      typing_event = body["extensions"]["typing"]["rooms"][room_id]
      assert typing_event["content"]["user_ids"] == [bob.user_id]
    end
  end

  describe "conn_id bandwidth diffing" do
    test "without conn_id, a repeated identical request still returns a full op and room entry" do
      alice = register("ss_diff_nokey_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"name" => "NoKey"})

      list_body = %{"lists" => %{"main" => basic_list()}}
      pos = sliding_sync(alice.token, list_body)["pos"]

      body2 = sliding_sync(alice.token, list_body, pos: pos)

      assert %{"ops" => [%{"op" => "SYNC", "room_ids" => [^room_id]}]} = body2["lists"]["main"]
      assert Map.has_key?(body2["rooms"], room_id)
    end

    test "with a conn_id, an unchanged range and room are omitted from the second response" do
      alice = register("ss_diff_alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"name" => "Diff"})

      list_body = %{"lists" => %{"main" => basic_list()}, "conn_id" => "conn-1"}
      body1 = sliding_sync(alice.token, list_body)
      pos = body1["pos"]

      assert %{"ops" => [%{"op" => "SYNC", "room_ids" => [^room_id]}]} = body1["lists"]["main"]
      assert Map.has_key?(body1["rooms"], room_id)

      body2 = sliding_sync(alice.token, list_body, pos: pos)

      assert %{"ops" => []} = body2["lists"]["main"]
      refute Map.has_key?(body2["rooms"], room_id)
    end

    test "with a conn_id, a room whose content changed is still resent even though its range didn't move" do
      alice = register("ss_diff_room_alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"name" => "DiffRoom"})

      list_body = %{"lists" => %{"main" => basic_list()}, "conn_id" => "conn-2"}
      pos = sliding_sync(alice.token, list_body)["pos"]

      send_event(alice.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "hi"})

      body2 = sliding_sync(alice.token, list_body, pos: pos)

      # Only one room in range, in the same position — the range itself
      # didn't change, so its SYNC op is skipped...
      assert %{"ops" => []} = body2["lists"]["main"]
      # ...but the room's own content did, so it's still resent.
      assert Map.has_key?(body2["rooms"], room_id)
      assert Enum.any?(body2["rooms"][room_id]["timeline"], &(&1["content"]["body"] == "hi"))
    end

    test "with a conn_id, a reordering across rooms still emits a SYNC op for the moved range" do
      alice = register("ss_diff_reorder_#{System.unique_integer([:positive])}")
      room_a = create_room(alice.token, %{"name" => "A"})
      room_b = create_room(alice.token, %{"name" => "B"})

      list_body = %{"lists" => %{"main" => basic_list()}, "conn_id" => "conn-3"}
      body1 = sliding_sync(alice.token, list_body)
      pos = body1["pos"]
      assert %{"ops" => [%{"room_ids" => [^room_b, ^room_a]}]} = body1["lists"]["main"]

      # Bump A's recency above B.
      send_event(alice.token, room_a, "m.room.message", %{"msgtype" => "m.text", "body" => "bump"})

      body2 = sliding_sync(alice.token, list_body, pos: pos)
      assert %{"ops" => [%{"room_ids" => [^room_a, ^room_b]}]} = body2["lists"]["main"]
    end

    test "different conn_ids on the same device get independent diffing state" do
      alice = register("ss_diff_multi_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"name" => "Multi"})

      list_body_a = %{"lists" => %{"main" => basic_list()}, "conn_id" => "tab-a"}
      pos = sliding_sync(alice.token, list_body_a)["pos"]

      # Second request on tab-a: nothing changed, diffed away.
      body_a2 = sliding_sync(alice.token, list_body_a, pos: pos)
      assert %{"ops" => []} = body_a2["lists"]["main"]
      refute Map.has_key?(body_a2["rooms"], room_id)

      # tab-b has never been seen on this connection, even reusing the same
      # pos token (which is connection-agnostic) — it still gets a full send.
      list_body_b = %{"lists" => %{"main" => basic_list()}, "conn_id" => "tab-b"}
      body_b = sliding_sync(alice.token, list_body_b, pos: pos)
      assert %{"ops" => [%{"op" => "SYNC"}]} = body_b["lists"]["main"]
      assert Map.has_key?(body_b["rooms"], room_id)
    end
  end
end
