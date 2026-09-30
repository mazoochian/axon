defmodule AxonWeb.RoomReadAccessTest do
  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  defp user(prefix), do: register("#{prefix}_#{System.unique_integer([:positive])}")

  defp room_path(room_id, suffix), do: "/_matrix/client/v3/rooms/#{room_id}#{suffix}"

  defp invite(token, room_id, user_id) do
    conn = authed(token) |> jp(room_path(room_id, "/invite"), %{"user_id" => user_id})
    assert conn.status == 200
  end

  defp join(token, room_id) do
    conn = authed(token) |> jp(room_path(room_id, "/join"), %{})
    assert conn.status == 200
  end

  defp put_state(token, room_id, type, content) do
    conn = authed(token) |> jpu(room_path(room_id, "/state/#{type}"), content)
    assert conn.status == 200
  end

  defp get_path(token, path), do: authed(token) |> get(path)

  describe "allowed-reader gate" do
    test "a never-member cannot list a private room's members" do
      alice = user("ra_alice")
      stranger = user("ra_stranger")
      room_id = create_room(alice.token, %{"preset" => "private_chat"})

      conn = get_path(stranger.token, room_path(room_id, "/members"))
      assert conn.status == 403
      assert decode(conn)["errcode"] == "M_FORBIDDEN"

      assert get_path(alice.token, room_path(room_id, "/members")).status == 200
    end

    test "an invited user cannot read state, members, threads, relations or context" do
      alice = user("ra_alice")
      bob = user("ra_bob")
      room_id = create_room(alice.token, %{"preset" => "private_chat"})
      event_id = send_event(alice.token, room_id, "m.room.message", %{"body" => "hi"})
      invite(alice.token, room_id, bob.user_id)

      for suffix <- [
            "/state",
            "/state/m.room.create/",
            "/members",
            "/context/#{event_id}"
          ] do
        assert get_path(bob.token, room_path(room_id, suffix)).status == 403, suffix
      end

      for path <- [
            "/_matrix/client/v1/rooms/#{room_id}/threads",
            "/_matrix/client/v1/rooms/#{room_id}/relations/#{event_id}"
          ] do
        assert get_path(bob.token, path).status == 403, path
      end
    end

    test "a world_readable room's state is readable by a non-member" do
      alice = user("ra_alice")
      stranger = user("ra_stranger")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      put_state(alice.token, room_id, "m.room.history_visibility", %{
        "history_visibility" => "world_readable"
      })

      assert get_path(stranger.token, room_path(room_id, "/state")).status == 200
      assert get_path(stranger.token, room_path(room_id, "/members")).status == 200
    end
  end

  describe "GET /context" do
    test "hides a pivot and neighbours from before the viewer could see history" do
      alice = user("ctx_alice")
      bob = user("ctx_bob")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      put_state(alice.token, room_id, "m.room.history_visibility", %{
        "history_visibility" => "joined"
      })

      hidden = send_event(alice.token, room_id, "m.room.message", %{"body" => "before"})
      join(bob.token, room_id)
      visible = send_event(alice.token, room_id, "m.room.message", %{"body" => "after"})

      assert get_path(bob.token, room_path(room_id, "/context/#{hidden}")).status == 404

      conn = get_path(bob.token, room_path(room_id, "/context/#{visible}?limit=20"))
      assert conn.status == 200
      before_ids = Enum.map(decode(conn)["events_before"], & &1["event_id"])
      refute hidden in before_ids
    end
  end

  describe "GET /messages" do
    test "rejects an invalid dir and tolerates a malformed limit" do
      alice = user("msg_alice")
      room_id = create_room(alice.token)

      conn = get_path(alice.token, room_path(room_id, "/messages?dir=x"))
      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_INVALID_PARAM"

      assert get_path(alice.token, room_path(room_id, "/messages?limit=abc")).status == 200
    end

    test "dir=b end token continues strictly past the page's oldest event" do
      alice = user("msg_alice")
      room_id = create_room(alice.token)

      ids =
        for i <- 1..4,
            do: send_event(alice.token, room_id, "m.room.message", %{"body" => "m#{i}"})

      page1 = decode(get_path(alice.token, room_path(room_id, "/messages?dir=b&limit=2")))
      assert Enum.map(page1["chunk"], & &1["event_id"]) == Enum.reverse(Enum.take(ids, -2))

      page2 =
        decode(
          get_path(
            alice.token,
            room_path(room_id, "/messages?dir=b&limit=2&from=#{page1["end"]}")
          )
        )

      assert Enum.map(page2["chunk"], & &1["event_id"]) ==
               ids |> Enum.slice(0, 2) |> Enum.reverse()
    end
  end

  describe "membership endpoints" do
    test "kick/ban/unban require a string user_id" do
      alice = user("mem_alice")
      room_id = create_room(alice.token)

      for action <- ["kick", "ban", "unban"] do
        conn = authed(alice.token) |> jp(room_path(room_id, "/#{action}"), %{})
        assert conn.status == 400, action
        assert decode(conn)["errcode"] == "M_MISSING_PARAM"
      end
    end

    test "unban of a user who isn't banned is forbidden" do
      alice = user("mem_alice")
      bob = user("mem_bob")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)

      conn = authed(alice.token) |> jp(room_path(room_id, "/unban"), %{"user_id" => bob.user_id})
      assert conn.status == 403

      assert get_path(bob.token, room_path(room_id, "/state")).status == 200
    end

    test "join and knock accept `via` as a server hint" do
      alice = user("mem_alice")

      Application.put_env(:axon_federation, :server_overrides, %{
        "via-hint.test" => "http://127.0.0.1:1"
      })

      on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)

      for path <- ["/_matrix/client/v3/join", "/_matrix/client/v3/knock"] do
        missing = authed(alice.token) |> jp("#{path}/!v12roomhash", %{})
        assert missing.status == 400

        conn = authed(alice.token) |> jp("#{path}/!v12roomhash?via=via-hint.test", %{})
        assert conn.status == 403, path
      end
    end

    test "inviting a remote user to an unknown room is a 404, not a 500" do
      alice = user("mem_alice")

      conn =
        authed(alice.token)
        |> jp(room_path("!nosuchroom:localhost", "/invite"), %{
          "user_id" => "@someone:remote.invalid"
        })

      assert conn.status == 404
    end
  end

  describe "/sync" do
    test "an ignored user inviting someone else doesn't hide our own invite" do
      alice = user("sync_alice")
      bob = user("sync_bob")
      carol = user("sync_carol")
      dave = user("sync_dave")

      room_id =
        create_room(bob.token, %{
          "preset" => "public_chat",
          "power_level_content_override" => %{"invite" => 0}
        })

      join(carol.token, room_id)
      invite(bob.token, room_id, alice.user_id)
      invite(carol.token, room_id, dave.user_id)

      conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/user/#{alice.user_id}/account_data/m.ignored_user_list", %{
          "ignored_users" => %{carol.user_id => %{}}
        })

      assert conn.status == 200

      body = decode(get_path(alice.token, "/_matrix/client/v3/sync"))
      assert Map.has_key?(body["rooms"]["invite"], room_id)
    end

    test "tolerates a malformed timeout and a non-object inline filter" do
      alice = user("sync_alice")

      assert get_path(alice.token, "/_matrix/client/v3/sync?timeout=abc").status == 200

      filter = URI.encode_www_form("[1]")
      assert get_path(alice.token, "/_matrix/client/v3/sync?filter=#{filter}").status == 200
    end

    test "m.read.private receipts are only shown to their owner" do
      alice = user("rcpt_alice")
      bob = user("rcpt_bob")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)
      event_id = send_event(alice.token, room_id, "m.room.message", %{"body" => "hi"})

      conn =
        authed(bob.token)
        |> jp(room_path(room_id, "/receipt/m.read.private/#{event_id}"), %{})

      assert conn.status == 200

      private_readers = fn token ->
        token
        |> get_path("/_matrix/client/v3/sync")
        |> decode()
        |> get_in(["rooms", "join", room_id, "ephemeral", "events"])
        |> Enum.filter(&(&1["type"] == "m.receipt"))
        |> Enum.flat_map(fn e -> Map.values(e["content"]) end)
        |> Enum.flat_map(fn by_type -> Map.keys(by_type["m.read.private"] || %{}) end)
      end

      assert private_readers.(alice.token) == []
      assert private_readers.(bob.token) == [bob.user_id]

      assert AxonWeb.SyncHelpers.read_receipt_ordering(room_id, bob.user_id) > 0
    end
  end

  describe "sliding sync" do
    @sliding_path "/_matrix/client/unstable/org.matrix.msc4186/sync"

    test "receipts/typing extensions skip invited rooms" do
      alice = user("ss_alice")
      bob = user("ss_bob")
      room_id = create_room(alice.token, %{"preset" => "private_chat"})
      event_id = send_event(alice.token, room_id, "m.room.message", %{"body" => "hi"})
      receipt = authed(alice.token) |> jp(room_path(room_id, "/receipt/m.read/#{event_id}"), %{})
      assert receipt.status == 200
      invite(alice.token, room_id, bob.user_id)

      body =
        authed(bob.token)
        |> jp(@sliding_path, %{
          "lists" => %{"all" => %{"ranges" => [[0, 10]]}},
          "extensions" => %{"receipts" => %{"enabled" => true}, "typing" => %{"enabled" => true}}
        })
        |> decode()

      assert Map.has_key?(body["rooms"], room_id)
      refute Map.has_key?(body["extensions"]["receipts"]["rooms"], room_id)
      refute Map.has_key?(body["extensions"]["typing"]["rooms"], room_id)
    end

    test "prev_batch paginates back from just before the timeline" do
      alice = user("ss_alice")
      room_id = create_room(alice.token)
      earlier = send_event(alice.token, room_id, "m.room.message", %{"body" => "1"})
      send_event(alice.token, room_id, "m.room.message", %{"body" => "2"})

      body =
        authed(alice.token)
        |> jp(@sliding_path, %{"room_subscriptions" => %{room_id => %{"timeline_limit" => 1}}})
        |> decode()

      prev_batch = body["rooms"][room_id]["prev_batch"]

      page =
        alice.token
        |> get_path(room_path(room_id, "/messages?dir=b&limit=1&from=#{prev_batch}"))
        |> decode()

      assert [%{"event_id" => ^earlier}] = page["chunk"]
    end
  end

  describe "receipts" do
    test "require joined membership and a known receipt type" do
      alice = user("rc_alice")
      stranger = user("rc_stranger")
      room_id = create_room(alice.token)
      event_id = send_event(alice.token, room_id, "m.room.message", %{"body" => "hi"})

      conn = authed(stranger.token) |> jp(room_path(room_id, "/receipt/m.read/#{event_id}"), %{})
      assert conn.status == 403

      conn = authed(alice.token) |> jp(room_path(room_id, "/receipt/m.bogus/#{event_id}"), %{})
      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_INVALID_PARAM"
    end

    test "m.fully_read via the receipt endpoint sets the room's fully-read marker" do
      alice = user("rc_alice")
      room_id = create_room(alice.token)
      event_id = send_event(alice.token, room_id, "m.room.message", %{"body" => "hi"})

      conn =
        authed(alice.token) |> jp(room_path(room_id, "/receipt/m.fully_read/#{event_id}"), %{})

      assert conn.status == 200

      assert [%{"content" => %{"event_id" => ^event_id}}] =
               room_id
               |> AxonWeb.SyncHelpers.build_room_account_data(alice.user_id)
               |> Enum.filter(&(&1["type"] == "m.fully_read"))
    end
  end

  describe "search" do
    test "rejects a non-object room_events and a non-list filter.rooms" do
      alice = user("search_alice")

      for categories <- [
            %{"room_events" => "x"},
            %{"room_events" => %{"search_term" => "hi", "filter" => %{"rooms" => "!r:x"}}}
          ] do
        conn =
          authed(alice.token)
          |> jp("/_matrix/client/v3/search", %{"search_categories" => categories})

        assert conn.status == 400
      end
    end
  end
end
