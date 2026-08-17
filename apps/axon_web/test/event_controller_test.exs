defmodule AxonWeb.EventControllerTest do
  @moduledoc "Tests EventController's redact action (thin/no prior coverage)."

  use AxonWeb.ConnCase, async: false

  alias AxonRoom.RoomProcess

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

  defp jpu(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token, opts \\ %{"preset" => "public_chat"}) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", opts)
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp send_message(token, room_id, content \\ %{"body" => "hi"}) do
    txn = "txn_#{System.unique_integer([:positive])}"

    conn =
      authed(token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn}", content)

    assert conn.status == 200
    decode(conn)["event_id"]
  end

  defp get_event(token, room_id, event_id) do
    authed(token) |> get("/_matrix/client/v3/rooms/#{room_id}/event/#{URI.encode(event_id)}")
  end

  defp join_room(token, room_id) do
    conn = authed(token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    assert conn.status == 200
  end

  defp leave_room(token, room_id) do
    conn = authed(token) |> jp("/_matrix/client/v3/rooms/#{room_id}/leave", %{})
    assert conn.status == 200
  end

  test "a user can redact their own event, and its content is stripped" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id = send_message(alice.token, room_id)

    txn = "txn_#{System.unique_integer([:positive])}"

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{
        "reason" => "oops"
      })

    assert conn.status == 200
    assert is_binary(decode(conn)["event_id"])

    after_conn = get_event(alice.token, room_id, event_id)
    assert decode(after_conn)["content"] == %{}
  end

  test "a moderator with redact power can redact another user's event, stripping its content" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    event_id = send_message(bob.token, room_id)

    txn = "txn_#{System.unique_integer([:positive])}"

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{})

    assert conn.status == 200

    after_conn = get_event(alice.token, room_id, event_id)
    assert decode(after_conn)["content"] == %{}
  end

  # Per spec (13.2 "Redactions"), the redaction event itself is *always*
  # accepted regardless of the sender's power — whether it actually
  # applies (strips the target's content) is a separate, server-local
  # policy: only the target's original sender or someone with the room's
  # "redact" power level (default 50). A user with neither still gets a
  # 200 for the redaction event, but the target's content survives.
  test "a user without redact power cannot strip another user's event content" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    charlie = register("charlie_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    authed(charlie.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    event_id = send_message(bob.token, room_id)

    txn = "txn_#{System.unique_integer([:positive])}"

    conn =
      authed(charlie.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{})

    assert conn.status == 200

    after_conn = get_event(alice.token, room_id, event_id)
    assert decode(after_conn)["content"] == %{"body" => "hi"}
  end

  # Regression: get_messages/2, get_state/2, and get_state_event/2 had no
  # membership check at all (get_state/get_state_event) or only checked
  # "forgotten" (get_messages) — meaning any authenticated user on the
  # server could read a private room's full timeline/state just by knowing
  # its room_id, never having been a member. get_relations/2 already had
  # the correct nil-membership check; the fix mirrors it.
  test "a stranger who was never a member cannot read messages, state, or a specific state event of a private room" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    stranger = register("stranger_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})
    send_message(alice.token, room_id)

    messages_conn = authed(stranger.token) |> get("/_matrix/client/v3/rooms/#{room_id}/messages")
    assert messages_conn.status == 403

    state_conn = authed(stranger.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state")
    assert state_conn.status == 403

    state_event_conn =
      authed(stranger.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.create/")

    assert state_event_conn.status == 403
  end

  test "a current member CAN read messages, state, and a specific state event" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})
    send_message(alice.token, room_id)

    assert authed(alice.token)
           |> get("/_matrix/client/v3/rooms/#{room_id}/messages")
           |> Map.get(:status) == 200

    assert authed(alice.token)
           |> get("/_matrix/client/v3/rooms/#{room_id}/state")
           |> Map.get(:status) == 200

    conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.create/")
    assert conn.status == 200
  end

  test "redact is idempotent per txn_id" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id = send_message(alice.token, room_id)
    txn = "txn_#{System.unique_integer([:positive])}"

    conn1 =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{})

    conn2 =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/#{txn}", %{})

    assert decode(conn1)["event_id"] == decode(conn2)["event_id"]
  end

  # GET /rooms/:room_id/context/:event_id — previously unimplemented (no
  # route at all, so it 404'd generically); found by Complement's
  # TestMSC4291RoomIDAsHashOfCreateEvent_RoomIDIsOnCreateEvent, which
  # reads the create event back through this endpoint among others.
  describe "get_context/2" do
    test "returns the target event with surrounding timeline and room state" do
      alice = register("ctx_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      ids = for _ <- 1..5, do: send_message(alice.token, room_id)
      target = Enum.at(ids, 2)

      conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/context/#{URI.encode(target)}?limit=4")

      assert conn.status == 200
      body = decode(conn)

      assert body["event"]["event_id"] == target
      assert body["event"]["room_id"] == room_id

      before_ids = Enum.map(body["events_before"], & &1["event_id"])
      after_ids = Enum.map(body["events_after"], & &1["event_id"])

      # events_before is reverse-chronological, events_after chronological,
      # and neither includes the target itself.
      refute target in before_ids
      refute target in after_ids
      assert Enum.at(ids, 1) in before_ids
      assert Enum.at(ids, 3) in after_ids

      state_types = Enum.map(body["state"], & &1["type"])
      assert "m.room.create" in state_types
      assert is_binary(body["start"]) and is_binary(body["end"])
    end

    test "404s for an event that doesn't exist, or belongs to another room" do
      alice = register("ctx_missing_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)
      other_room = create_room(alice.token)
      other_event = send_message(alice.token, other_room)

      missing =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/context/%24nope")

      assert missing.status == 404

      wrong_room =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/context/#{URI.encode(other_event)}")

      assert wrong_room.status == 404
    end

    test "403s for a non-member" do
      alice = register("ctx_owner_#{System.unique_integer([:positive])}")
      mallory = register("ctx_outsider_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "private_chat"})
      event_id = send_message(alice.token, room_id)

      conn =
        authed(mallory.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/context/#{URI.encode(event_id)}")

      assert conn.status == 403
    end

    # Regression (Complement TestJumpToDateEndpoint's federation "can
    # paginate backwards after getting remote event from timestamp to event
    # endpoint" subtests, both (start) and (end)): `get_context/2` used to
    # window `events_before`/`events_after` via `get_messages/4`, bounding
    # purely on the *target* event's own `stream_ordering`. That's wrong
    # when the target is itself a federation-backfilled event, whose
    # `stream_ordering` reflects local insertion time, not DAG position —
    # exactly `AxonCore.EventStore.get_context_neighbors/4`'s bug (see its
    # doc). This reproduces the shape live over HTTP: a remote member joins
    # the room (getting a *low* stream_ordering, inserted early) before two
    # older-in-the-DAG events backfill in after it (getting *higher*
    # stream_ordering despite lower depth) — the same skew a real
    # `timestamp_to_event`-triggered backfill produces once a remote server
    # has already joined a room before asking about its older history.
    test "start/end tokens stay correct when the context target is a backfilled event with skewed stream_ordering" do
      alice = register("ctx_skew_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      {last_event_id, depth} = RoomProcess.get_position(room_id)
      remote_user = "@charlie:federated.example"

      # Applied FIRST (like a remote member's own join): low stream_ordering,
      # but the deepest event in the room once A and B land.
      future_pdu = %{
        "event_id" => "$ctxskew_future_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.member",
        "state_key" => remote_user,
        "sender" => remote_user,
        "content" => %{"membership" => "join"},
        "depth" => depth + 3,
        "prev_events" => [last_event_id],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      {:ok, _future_id} = RoomProcess.apply_remote_event(room_id, future_pdu)

      # Applied SECOND, backfilling in after the "future" event above: gets
      # a higher stream_ordering than it despite a lower depth. Chained off
      # `last_event_id` (not the "future" join) and sent by `alice`, who's
      # already a joined member -- like the real scenario, where A/B are
      # alice's own messages, sent (and locally causally ordered) before
      # the remote member ever joined; only *this* server's local insertion
      # order (via the simulated late-backfill below) is skewed relative to
      # that.
      event_a_pdu = %{
        "event_id" => "$ctxskew_a_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => alice.user_id,
        "content" => %{"body" => "Event A"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      {:ok, event_a_id} = RoomProcess.apply_remote_event(room_id, event_a_pdu)

      # Applied LAST: the /context target. Highest stream_ordering in the
      # room, but a lower depth than the "future" event.
      event_b_pdu = %{
        "event_id" => "$ctxskew_b_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => alice.user_id,
        "content" => %{"body" => "Event B"},
        "depth" => depth + 2,
        "prev_events" => [event_a_id],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      {:ok, event_b_id} = RoomProcess.apply_remote_event(room_id, event_b_pdu)

      context_body =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/context/#{URI.encode(event_b_id)}?limit=0")
        |> decode()

      start_token = context_body["start"]
      end_token = context_body["end"]
      assert is_binary(start_token) and is_binary(end_token)

      # Paginating backwards from "start" (the boundary just before B) must
      # still surface A, even though A's stream_ordering is higher than the
      # future event's that the old, stream_ordering-only bound would have
      # wrongly anchored "start" to.
      from_start =
        authed(alice.token)
        |> get(
          "/_matrix/client/v3/rooms/#{room_id}/messages?dir=b&limit=100&from=#{URI.encode_www_form(start_token)}"
        )
        |> decode()
        |> Map.fetch!("chunk")
        |> Enum.map(& &1["event_id"])

      assert event_a_id in from_start

      # Paginating backwards from "end" (the boundary just after B) must
      # surface both A and B themselves — B's own stream_ordering is the
      # highest in the room, so a boundary that merely equals it (rather
      # than exceeding it) would silently exclude B.
      from_end =
        authed(alice.token)
        |> get(
          "/_matrix/client/v3/rooms/#{room_id}/messages?dir=b&limit=100&from=#{URI.encode_www_form(end_token)}"
        )
        |> decode()
        |> Map.fetch!("chunk")
        |> Enum.map(& &1["event_id"])

      assert event_a_id in from_end
      assert event_b_id in from_end
    end
  end

  # `filter={"lazy_load_members":true}` on /messages — previously always
  # returned "state": [] regardless. Now returns the current m.room.member
  # event for each sender present in the returned chunk, deduplicated.
  describe "get_messages/2 lazy_load_members" do
    test "returns member events for senders present in the chunk" do
      alice = register("llm_#{System.unique_integer([:positive])}")
      bob = register("llm_bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)
      authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})

      send_message(alice.token, room_id)
      send_message(bob.token, room_id)

      filter = URI.encode_www_form(Jason.encode!(%{"lazy_load_members" => true}))

      conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/messages?filter=#{filter}")

      assert conn.status == 200
      body = decode(conn)

      state_senders =
        body["state"] |> Enum.map(& &1["state_key"]) |> Enum.sort()

      assert state_senders == Enum.sort([alice.user_id, bob.user_id])
      assert Enum.all?(body["state"], &(&1["type"] == "m.room.member"))
    end

    test "omits state entirely without the filter" do
      alice = register("llm_off_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)
      send_message(alice.token, room_id)

      conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/messages")
      assert decode(conn)["state"] == []
    end
  end

  describe "get_messages/2 contains_url" do
    test "filter={contains_url:true} returns only events whose content has a url key" do
      alice = register("curl_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)
      send_message(alice.token, room_id, %{"body" => "no url here"})

      with_url =
        send_message(alice.token, room_id, %{
          "body" => "test.png",
          "msgtype" => "m.file",
          "url" => "mxc://localhost/abc"
        })

      filter = URI.encode_www_form(Jason.encode!(%{"contains_url" => true}))

      conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/messages?filter=#{filter}&limit=10")

      assert conn.status == 200
      chunk = decode(conn)["chunk"]
      assert Enum.map(chunk, & &1["event_id"]) == [with_url]
    end

    test "filter={contains_url:false} excludes events whose content has a url key" do
      alice = register("curl_false_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      without_url = send_message(alice.token, room_id, %{"body" => "no url here"})

      with_url =
        send_message(alice.token, room_id, %{
          "body" => "test.png",
          "msgtype" => "m.file",
          "url" => "mxc://localhost/abc"
        })

      filter = URI.encode_www_form(Jason.encode!(%{"contains_url" => false}))

      conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/messages?filter=#{filter}&limit=10")

      event_ids = decode(conn)["chunk"] |> Enum.map(& &1["event_id"])
      assert without_url in event_ids
      refute with_url in event_ids
    end
  end

  describe "get_messages/2 history visibility" do
    # Regression: get_messages/2 fetched a page purely by stream_ordering
    # and applied no history_visibility filtering at all — a joined
    # member saw the room's entire retained history regardless of
    # history_visibility's invited/joined settings. Shares its rules with
    # GET /event/{id} via EventController.visibility_bounds/2 +
    # event_visible?/2, computed once per request rather than per event.
    test "a member sees only events sent after they joined when visibility is 'joined'" do
      alice = register("alice_msgvis_#{System.unique_integer([:positive])}")
      bob = register("bob_msgvis_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      pre_join_event = send_message(alice.token, room_id, %{"body" => "before bob joined"})

      vis_conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/m.room.history_visibility", %{
          "history_visibility" => "joined"
        })

      assert vis_conn.status == 200

      join_room(bob.token, room_id)
      post_join_event = send_message(alice.token, room_id, %{"body" => "after bob joined"})

      conn =
        authed(bob.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/messages?dir=b&limit=20")

      event_ids = decode(conn)["chunk"] |> Enum.map(& &1["event_id"])
      assert post_join_event in event_ids
      refute pre_join_event in event_ids
    end

    test "a member sees the full history when visibility is 'shared' (the default)" do
      alice = register("alice_msgvisshared_#{System.unique_integer([:positive])}")
      bob = register("bob_msgvisshared_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      pre_join_event = send_message(alice.token, room_id, %{"body" => "before bob joined"})
      join_room(bob.token, room_id)

      conn =
        authed(bob.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/messages?dir=b&limit=20")

      event_ids = decode(conn)["chunk"] |> Enum.map(& &1["event_id"])
      assert pre_join_event in event_ids
    end
  end

  describe "get_event/2 history visibility for a user who has left the room" do
    # Regression: can_access_event?/3's membership case had no branch for
    # "leave" or "ban" at all — every non-"join" membership fell through
    # to the catch-all `false`, so a user who left a room could never see
    # ANY of its history via GET /event/{id} again, even a message sent
    # while they were still a member and had every right to see it. A
    # closed README "Known gaps" item ("history visibility for a user
    # who's left a room" needs point-in-time state).
    test "a left member can still see an event sent while they were joined (shared visibility)" do
      alice = register("alice_hvleft1_#{System.unique_integer([:positive])}")
      bob = register("bob_hvleft1_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      join_room(bob.token, room_id)
      event_id = send_message(alice.token, room_id, %{"body" => "while bob was here"})
      leave_room(bob.token, room_id)

      conn = get_event(bob.token, room_id, event_id)
      assert conn.status == 200
      assert decode(conn)["event_id"] == event_id
    end

    test "a left member cannot see an event sent after they left (shared visibility)" do
      alice = register("alice_hvleft2_#{System.unique_integer([:positive])}")
      bob = register("bob_hvleft2_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      join_room(bob.token, room_id)
      leave_room(bob.token, room_id)
      event_id = send_message(alice.token, room_id, %{"body" => "after bob left"})

      conn = get_event(bob.token, room_id, event_id)
      assert conn.status == 404
    end

    test "a banned member can still see an event sent while they were joined" do
      alice = register("alice_hvban_#{System.unique_integer([:positive])}")
      bob = register("bob_hvban_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      join_room(bob.token, room_id)
      event_id = send_message(alice.token, room_id, %{"body" => "while bob was here"})

      ban_conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/ban", %{"user_id" => bob.user_id})

      assert ban_conn.status == 200

      conn = get_event(bob.token, room_id, event_id)
      assert conn.status == 200
      assert decode(conn)["event_id"] == event_id
    end

    test "a left member cannot see a pre-join event when visibility is 'joined'" do
      alice = register("alice_hvjoined_#{System.unique_integer([:positive])}")
      bob = register("bob_hvjoined_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      pre_join_event = send_message(alice.token, room_id, %{"body" => "before bob joined"})

      vis_conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/m.room.history_visibility", %{
          "history_visibility" => "joined"
        })

      assert vis_conn.status == 200

      join_room(bob.token, room_id)
      post_join_event = send_message(alice.token, room_id, %{"body" => "after bob joined"})
      leave_room(bob.token, room_id)

      refute get_event(bob.token, room_id, pre_join_event).status == 200
      assert get_event(bob.token, room_id, post_join_event).status == 200
    end
  end

  describe "point-in-time state/messages for a departed member (Complement TestLeftRoomFixture, SPEC-216)" do
    # Regression: GET /state/:type/:state_key (and /state) routed every
    # request through RoomProcess, which only ever holds the room's
    # *live* current state — a member who left before some later state
    # change (a name change, some other bit of state) saw the room's
    # current value anyway, not the value as of when they left. Per spec
    # a departed member should see the room frozen at their leave point.
    test "get_state_event/2 returns the value as of when a departed member left, not the current value" do
      alice = register("alice_depstate_#{System.unique_integer([:positive])}")
      bob = register("bob_depstate_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      join_room(bob.token, room_id)

      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/m.room.name/", %{"name" => "before"})

      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/madeup.test.state/", %{"body" => "before"})

      leave_room(bob.token, room_id)

      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/m.room.name/", %{"name" => "after"})

      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/madeup.test.state/", %{"body" => "after"})

      bob_name =
        authed(bob.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.name/")

      assert bob_name.status == 200
      assert decode(bob_name)["name"] == "before"

      bob_madeup =
        authed(bob.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/state/madeup.test.state/")

      assert bob_madeup.status == 200
      assert decode(bob_madeup)["body"] == "before"

      # Alice, still joined, gets the live current value.
      alice_name =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.name/")

      assert decode(alice_name)["name"] == "after"
    end

    test "get_state/2 (full room state) is frozen at a departed member's leave point too" do
      alice = register("alice_depstatefull_#{System.unique_integer([:positive])}")
      bob = register("bob_depstatefull_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      join_room(bob.token, room_id)

      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/m.room.name/", %{"name" => "before"})

      leave_room(bob.token, room_id)

      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/m.room.name/", %{"name" => "after"})

      conn = authed(bob.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state")
      assert conn.status == 200

      name_event = decode(conn) |> Enum.find(&(&1["type"] == "m.room.name"))
      assert name_event["content"]["name"] == "before"

      # Bob's own leave event is part of the state as of his leave point.
      bob_member =
        decode(conn)
        |> Enum.find(&(&1["type"] == "m.room.member" and &1["state_key"] == bob.user_id))

      assert bob_member["content"]["membership"] == "leave"
    end

    # Regression: EventStore.get_messages/4's dir=b query is exclusive of
    # its `from_ordering` boundary by design (see event_store_test.exs's
    # `stream_ordering + 1` convention). A departed member's own leave
    # event is very often exactly that boundary — a `from` token lifted
    # from their own /sync `next_batch` right after leaving carries their
    # leave event's own stream_ordering, since that was the newest event
    # ever delivered to them. Left unhandled, the exclusive boundary
    # silently dropped that one legitimate, already-seen event off a
    # backward /messages page.
    test "get_messages/2 dir=b from a departed member's own post-leave sync token includes their leave event" do
      alice = register("alice_depmsg_#{System.unique_integer([:positive])}")
      bob = register("bob_depmsg_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      join_room(bob.token, room_id)
      send_message(alice.token, room_id, %{"body" => "M1"})
      send_message(alice.token, room_id, %{"body" => "M2"})
      leave_room(bob.token, room_id)

      bob_since =
        authed(bob.token)
        |> get("/_matrix/client/v3/sync")
        |> decode()
        |> Map.fetch!("next_batch")

      # Events after bob left must not leak into his page even though the
      # boundary nudge above admits a couple of extra rows to the raw fetch.
      send_message(alice.token, room_id, %{"body" => "M3"})

      conn =
        authed(bob.token)
        |> get(
          "/_matrix/client/v3/rooms/#{room_id}/messages?dir=b&limit=3&from=#{URI.encode_www_form(bob_since)}"
        )

      assert conn.status == 200
      chunk = decode(conn)["chunk"]

      assert Enum.any?(
               chunk,
               &(&1["type"] == "m.room.member" and &1["state_key"] == bob.user_id and
                   &1["content"]["membership"] == "leave")
             )

      bodies = chunk |> Enum.map(&get_in(&1, ["content", "body"])) |> Enum.reject(&is_nil/1)
      assert "M1" in bodies
      assert "M2" in bodies
      refute "M3" in bodies
    end
  end

  # Regression (Complement TestNetworkPartitionOrdering): a room's
  # `/sync` `timeline.prev_batch` was computed as
  # `hd(tl_events).stream_ordering - 1`. EventStore.get_messages/4's
  # dir=b bound (`stream_ordering < from_ordering`) is already exclusive
  # of `from_ordering` itself, so that extra `- 1` over-excluded by one:
  # it silently dropped the single room event immediately preceding the
  # returned timeline off the very next backward `/messages` page.
  #
  # This reproduces the Complement scenario directly: two local users
  # (alice, bob) plus a simulated remote member (via
  # `RoomProcess.apply_remote_event/2`, same pattern as this module's
  # other federation-shaped regressions) who forks an event off an
  # earlier point in the DAG than the local room head, then only
  # "arrives" after several local events already advanced past it —
  # network-partition-style. Depth-tying between the forked event's
  # later local siblings (events 5-7) and the earlier ones (1-4) is a
  # separate concern (see event_store_test.exs's "get_messages backwards
  # (dir=b) depth ordering") — this test isolates the boundary/off-by-one
  # bug by keeping the window (`from` prev_batch) to exactly the four
  # events sent *before* the fork resolves, where depths are already
  # strictly increasing and can't mask a boundary-exclusion bug.
  describe "prev_batch -> /messages dir=b pagination boundary (Complement TestNetworkPartitionOrdering)" do
    test "a backward page from sync's prev_batch includes the event right before the timeline window, not just older ones" do
      alice = register("alice_netpart_#{System.unique_integer([:positive])}")
      bob = register("bob_netpart_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      join_room(bob.token, room_id)

      remote_user = "@charlie:federated.example"
      {last_event_id, depth} = RoomProcess.get_position(room_id)

      charlie_join_pdu = %{
        "event_id" => "$netpart_charlie_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.member",
        "state_key" => remote_user,
        "sender" => remote_user,
        "content" => %{"membership" => "join"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      {:ok, charlie_join_id} = RoomProcess.apply_remote_event(room_id, charlie_join_pdu)
      {_, charlie_depth} = RoomProcess.get_position(room_id)

      # Built by the remote server against ITS OWN known head (charlie's
      # own join) -- it doesn't yet know about bob's local join, matching
      # the real race: bob's join federates out asynchronously and this
      # event is created before that transaction is guaranteed to land.
      event1prime_pdu = %{
        "event_id" => "$netpart_prime_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => remote_user,
        "content" => %{"body" => "Event 1'"},
        "depth" => charlie_depth + 1,
        "prev_events" => [charlie_join_id],
        "auth_events" => [],
        "origin" => "federated.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      bob_since =
        authed(bob.token)
        |> get("/_matrix/client/v3/sync")
        |> decode()
        |> Map.fetch!("next_batch")

      event_ids = for i <- 1..4, do: send_message(alice.token, room_id, %{"body" => "event #{i}"})

      {:ok, _} = RoomProcess.apply_remote_event(room_id, event1prime_pdu)

      for i <- 5..7, do: send_message(alice.token, room_id, %{"body" => "event #{i}"})

      filter = Jason.encode!(%{"room" => %{"timeline" => %{"limit" => 4}}})

      sync_body =
        authed(bob.token)
        |> get(
          "/_matrix/client/v3/sync?since=#{URI.encode_www_form(bob_since)}&filter=#{URI.encode_www_form(filter)}"
        )
        |> decode()

      prev_batch = get_in(sync_body, ["rooms", "join", room_id, "timeline", "prev_batch"])
      refute is_nil(prev_batch)

      conn =
        authed(alice.token)
        |> get(
          "/_matrix/client/v3/rooms/#{room_id}/messages?dir=b&limit=4&from=#{URI.encode_www_form(prev_batch)}"
        )

      assert conn.status == 200
      got_ids = decode(conn)["chunk"] |> Enum.map(& &1["event_id"])

      assert got_ids == Enum.reverse(event_ids)
    end
  end

  # Regression: GET /event/{id} used the shared, unfiltered
  # AxonCore.EventStore.get_event/1 (no `rejected`/`soft_failed` check at
  # all — unlike every other client-facing query in that module), so an
  # event that RoomProcess had correctly rejected (including the transitive
  # case: a legitimate event whose auth_events reference an
  # already-rejected/unknown ancestor, per any_rejected?/unknown_ids) was
  # still served back to clients with a 200 instead of 404.
  #
  # Complement: TestInboundFederationRejectsEventsWithRejectedAuthEvents
  # asserts exactly this — the outlier event 404s (it was simply never
  # stored, a different code path entirely), but two ordinary events that
  # list the outlier in their own auth_events must *also* 404, because they
  # were transitively rejected. RoomProcess's rejection logic (covered by
  # apps/axon_room/test/room_process_test.exs, "transitive auth rejection")
  # already stored them correctly as `rejected: true`; this test covers the
  # client read path that was failing to honor that flag.
  describe "get_event/2 and transitively rejected events" do
    test "a client GET 404s for an event whose auth_events reference an already-rejected event" do
      alice = register("alice_txreject_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token)

      {last_event_id, depth} = RoomProcess.get_position(room_id)

      # An outright-rejected ancestor: an unjoined remote sender's event
      # fails auth checking and is stored with rejected: true.
      rejected_id = "$rejected_ancestor_#{System.unique_integer([:positive])}"

      rejected_pdu = %{
        "event_id" => rejected_id,
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => "@intruder:remote.example",
        "content" => %{"body" => "should not land"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [],
        "origin" => "remote.example",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      assert RoomProcess.apply_remote_event(room_id, rejected_pdu) == {:error, :not_joined}

      # A perfectly ordinary event from the room's own creator, except it
      # lists the rejected event as one of its auth_events — per spec this
      # must itself be rejected regardless of what auth-checking against
      # current state would otherwise say.
      dependent_id = "$dependent_#{System.unique_integer([:positive])}"

      dependent_pdu = %{
        "event_id" => dependent_id,
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => alice.user_id,
        "content" => %{"body" => "hi"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [rejected_id],
        "origin" => "localhost",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      assert RoomProcess.apply_remote_event(room_id, dependent_pdu) ==
               {:error, :auth_event_rejected}

      # The outlier itself was never stored under any key at all (a
      # different code path — EventStore.unknown_ids/1 — from the
      # already-rejected case above), so it 404s too, matching Complement's
      # own first assertion.
      never_seen_id = "$never_seen_outlier_#{System.unique_integer([:positive])}"

      other_dependent_id = "$dependent2_#{System.unique_integer([:positive])}"

      other_dependent_pdu = %{
        "event_id" => other_dependent_id,
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => alice.user_id,
        "content" => %{"body" => "hi again"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "auth_events" => [never_seen_id],
        "origin" => "localhost",
        "origin_server_ts" => System.os_time(:millisecond)
      }

      assert RoomProcess.apply_remote_event(room_id, other_dependent_pdu) ==
               {:error, :unknown_auth_event}

      assert get_event(alice.token, room_id, rejected_id).status == 404
      assert get_event(alice.token, room_id, never_seen_id).status == 404
      assert get_event(alice.token, room_id, dependent_id).status == 404
      assert get_event(alice.token, room_id, other_dependent_id).status == 404
    end
  end
end
