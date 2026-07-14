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
end
