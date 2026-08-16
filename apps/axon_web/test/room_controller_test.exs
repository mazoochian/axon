defmodule AxonWeb.RoomControllerTest do
  @moduledoc """
  Tests `RoomController` actions with thin/no prior coverage: kick, ban,
  unban, knock, members, joined_members, typing. (create/join already get
  substantial indirect coverage via the `create_room`/`register` helpers
  used throughout the rest of the suite.)
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

  defp jpu(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token, opts) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", opts)
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp join(token, room_id) do
    conn = authed(token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    assert conn.status == 200
  end

  describe "kick" do
    test "a joined member with kick power can kick another joined member" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)

      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/kick", %{
          "user_id" => bob.user_id,
          "reason" => "spamming"
        })

      assert conn.status == 200

      members_conn =
        authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/members?membership=leave")

      assert Enum.any?(decode(members_conn)["chunk"], &(&1["state_key"] == bob.user_id))
    end

    test "a member without kick power cannot kick another" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      charlie = register("charlie_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)
      join(charlie.token, room_id)

      conn =
        authed(bob.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/kick", %{"user_id" => charlie.user_id})

      assert conn.status in [400, 403]
    end
  end

  describe "ban / unban" do
    test "banning a member removes them and prevents rejoin, unban allows rejoin" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)

      ban_conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/ban", %{
          "user_id" => bob.user_id,
          "reason" => "rule violation"
        })

      assert ban_conn.status == 200

      rejoin_conn = authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
      assert rejoin_conn.status == 403

      unban_conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/unban", %{"user_id" => bob.user_id})

      assert unban_conn.status == 200

      rejoin_conn2 = authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
      assert rejoin_conn2.status == 200
    end
  end

  describe "knock" do
    test "knocking on a knock-enabled room succeeds and shows a preview" do
      alice = register("alice_#{System.unique_integer([:positive])}")

      room_id =
        create_room(alice.token, %{
          "name" => "Knockable Room",
          "initial_state" => [
            %{"type" => "m.room.join_rules", "content" => %{"join_rule" => "knock"}}
          ]
        })

      bob = register("bob_#{System.unique_integer([:positive])}")

      conn =
        authed(bob.token)
        |> jp("/_matrix/client/v3/knock/#{room_id}", %{"reason" => "let me in please"})

      assert conn.status == 200
      assert decode(conn)["room_id"] == room_id
    end

    test "knocking on a non-knockable room is rejected" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "private_chat"})

      bob = register("bob_#{System.unique_integer([:positive])}")
      conn = authed(bob.token) |> jp("/_matrix/client/v3/knock/#{room_id}", %{})
      assert conn.status in [400, 403]
    end
  end

  describe "members / joined_members" do
    test "members lists all membership states by default" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)

      conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/members")
      state_keys = decode(conn)["chunk"] |> Enum.map(& &1["state_key"])
      assert alice.user_id in state_keys
      assert bob.user_id in state_keys
    end

    test "members can be filtered by membership state" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)

      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/kick", %{"user_id" => bob.user_id})

      conn =
        authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/members?membership=join")

      state_keys = decode(conn)["chunk"] |> Enum.map(& &1["state_key"])
      assert alice.user_id in state_keys
      refute bob.user_id in state_keys
    end

    test "members can be filtered by not_membership" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join(bob.token, room_id)
      authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/leave", %{})

      conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/members?not_membership=leave")

      state_keys = decode(conn)["chunk"] |> Enum.map(& &1["state_key"])
      assert alice.user_id in state_keys
      refute bob.user_id in state_keys
    end

    test "members?at=<token> returns membership as of that point, not current" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      before_bob_token =
        authed(alice.token) |> get("/_matrix/client/v3/sync") |> decode() |> Map.fetch!("next_batch")

      join(bob.token, room_id)

      after_bob_token =
        authed(alice.token) |> get("/_matrix/client/v3/sync") |> decode() |> Map.fetch!("next_batch")

      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/kick", %{"user_id" => bob.user_id})

      # As of before bob joined: only alice.
      before_conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/members?at=#{before_bob_token}")

      before_keys = decode(before_conn)["chunk"] |> Enum.map(& &1["state_key"])
      assert alice.user_id in before_keys
      refute bob.user_id in before_keys

      # As of right after bob joined (but before the later kick): both,
      # and bob still shows "join" even though he's since been kicked.
      after_conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/members?at=#{after_bob_token}")

      after_chunk = decode(after_conn)["chunk"]
      after_keys = Enum.map(after_chunk, & &1["state_key"])
      assert alice.user_id in after_keys
      assert bob.user_id in after_keys

      bob_entry = Enum.find(after_chunk, &(&1["state_key"] == bob.user_id))
      assert bob_entry["membership"] == "join"

      # Current (no "at"): bob is leave, reflecting the kick.
      current_conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/members")
      current_chunk = decode(current_conn)["chunk"]
      current_bob = Enum.find(current_chunk, &(&1["state_key"] == bob.user_id))
      assert current_bob["membership"] == "leave"
    end

    # Regression (Complement TestGetRoomMembersAtPoint): a room's own
    # `timeline.prev_batch` (as opposed to the top-level `next_batch` the
    # test above uses) was hardcoded to "0" whenever that sync response
    # wasn't `limited` — which every small, non-truncated room's sync
    # always is. `at=0` then always resolved to "before this room's very
    # first event", so `?members?at=<a room's own prev_batch>` came back
    # empty instead of the membership actually visible in that response.
    test "members?at=<a room's own sync prev_batch> returns membership as of that snapshot" do
      alice = register("alice_pb_#{System.unique_integer([:positive])}")
      bob = register("bob_pb_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      txn = "txn_#{System.unique_integer([:positive])}"

      authed(alice.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn}", %{
        "msgtype" => "m.text",
        "body" => "Hello world!"
      })

      sync_body = authed(alice.token) |> get("/_matrix/client/v3/sync") |> decode()
      prev_batch = get_in(sync_body, ["rooms", "join", room_id, "timeline", "prev_batch"])
      refute prev_batch == "0"

      join(bob.token, room_id)

      conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/members?at=#{prev_batch}")

      state_keys = decode(conn)["chunk"] |> Enum.map(& &1["state_key"])
      assert alice.user_id in state_keys
      refute bob.user_id in state_keys
    end

    # Regression (Complement TestLeftRoomFixture / members_for_a_departed_room,
    # SPEC-216): GET /members with no `at` always answered with current, live
    # membership — so a departed member asking "who was here" saw anyone who
    # joined *after* they left. Per spec, no `at` + a requester who has left
    # (or been banned) should default to membership as of when they left.
    test "members with no ?at, for a departed requester, excludes members who joined after they left" do
      alice = register("alice_dep_#{System.unique_integer([:positive])}")
      bob = register("bob_dep_#{System.unique_integer([:positive])}")
      charlie = register("charlie_dep_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      join(bob.token, room_id)

      authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/leave", %{})

      join(charlie.token, room_id)

      conn = authed(bob.token) |> get("/_matrix/client/v3/rooms/#{room_id}/members")
      chunk = decode(conn)["chunk"]
      state_keys = Enum.map(chunk, & &1["state_key"])

      assert alice.user_id in state_keys
      assert bob.user_id in state_keys
      refute charlie.user_id in state_keys

      bob_entry = Enum.find(chunk, &(&1["state_key"] == bob.user_id))
      assert bob_entry["membership"] == "leave"

      # A currently-joined requester is unaffected: still gets live membership.
      current_conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/members")
      current_keys = decode(current_conn)["chunk"] |> Enum.map(& &1["state_key"])
      assert charlie.user_id in current_keys
    end

    test "joined_members requires the requester to be joined" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "private_chat"})

      conn = authed(bob.token) |> get("/_matrix/client/v3/rooms/#{room_id}/joined_members")
      assert conn.status == 403
    end

    test "joined_members returns display info for current members" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/joined_members")
      assert conn.status == 200
      assert Map.has_key?(decode(conn)["joined"], alice.user_id)
    end
  end

  describe "join content" do
    # Per spec, the client's POST body becomes the m.room.member join
    # event's content (alongside "membership"), e.g. a custom "foo": "bar"
    # field — Complement's TestRoomMembers caught this being dropped
    # entirely.
    test "extra fields in the join body land on the stored m.room.member event, but can't forge membership" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      conn =
        authed(bob.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{
          "foo" => "bar",
          "membership" => "leave"
        })

      assert conn.status == 200

      state_conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.member/#{bob.user_id}")

      content = decode(state_conn)
      assert content["foo"] == "bar"
      assert content["membership"] == "join"
    end
  end

  describe "typing" do
    test "PUT typing always returns an empty ack (stub, not persisted)" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{})

      conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/rooms/#{room_id}/typing/#{alice.user_id}", %{
          "typing" => true,
          "timeout" => 30_000
        })

      assert conn.status == 200
      assert decode(conn) == %{}
    end
  end

  describe "forget" do
    test "cannot forget a room you're still joined to" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{})

      conn = authed(alice.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/forget", %{})
      assert conn.status == 400
    end

    test "can forget a room after leaving" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      bob = register("bob_#{System.unique_integer([:positive])}")
      join(bob.token, room_id)
      authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/leave", %{})

      conn = authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/forget", %{})
      assert conn.status == 200
    end
  end

  describe "join/knock with a ?server_name= via-hint (regression)" do
    # Found via Complement: Phoenix/Plug hands `params["server_name"]` back
    # as a bare string for a single `?server_name=x`, not a list — the
    # alias-resolution branch in RoomController.resolve_room/3 assumed a
    # list unconditionally and crashed (Enumerable not implemented for
    # BitString) instead of the clean 404 a nonexistent room should give.
    # 127.0.0.1:1 is a real connect-refused (nothing listens there), not a
    # DNS timeout, so this stays fast.

    test "a single server_name query param no longer crashes an alias join to a nonexistent room" do
      alice = register("alice_hint1_#{System.unique_integer([:positive])}")
      room_alias = "%23nonexistent_#{System.unique_integer([:positive])}:remote.invalid"

      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/join/#{room_alias}?server_name=127.0.0.1:1", %{})

      assert conn.status == 404
      assert decode(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "a repeated server_name query param no longer crashes an alias join to a nonexistent room" do
      alice = register("alice_hint2_#{System.unique_integer([:positive])}")
      room_alias = "%23nonexistent_#{System.unique_integer([:positive])}:remote.invalid"

      conn =
        authed(alice.token)
        |> jp(
          "/_matrix/client/v3/join/#{room_alias}?server_name=127.0.0.1:1&server_name=127.0.0.1:2",
          %{}
        )

      assert conn.status == 404
      assert decode(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "a single server_name query param no longer crashes a knock on a nonexistent alias" do
      alice = register("alice_hint3_#{System.unique_integer([:positive])}")
      room_alias = "%23nonexistent_#{System.unique_integer([:positive])}:remote.invalid"

      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/knock/#{room_alias}?server_name=127.0.0.1:1", %{})

      assert conn.status == 404
      assert decode(conn)["errcode"] == "M_NOT_FOUND"
    end
  end

  describe "join by remote alias (regression)" do
    # Every Matrix alias starts with "#" — RoomController.resolve_remote_alias/3
    # interpolated it into a federation query string with URI.encode/1, which
    # leaves "#" unescaped. Finch.build/5 then re-parses that URL string with
    # URI.parse/1, which treats an unescaped "#" as the start of a fragment —
    # so the alias never made it onto the wire, only an empty room_alias= did,
    # and every federated alias-join 404'd (Complement: TestOutboundFederationSend,
    # TestNetworkPartitionOrdering, both of which join a remote room by alias).
    test "resolves the remote alias via a correctly query-encoded federation lookup" do
      port = 19_460
      server_name = "fake-roomjoin-alias.test"

      start_supervised!({AxonFederation.FakeRemoteMatrixServer, port: port, server_name: server_name})

      Application.put_env(:axon_federation, :server_overrides, %{
        server_name => "http://127.0.0.1:#{port}"
      })

      on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)

      alice = register("alice_aliasjoin_#{System.unique_integer([:positive])}")
      full_alias = "#flibble_#{System.unique_integer([:positive])}:#{server_name}"
      remote_room_id = "!remoteroom#{System.unique_integer([:positive])}:#{server_name}"

      AxonFederation.FakeRemoteMatrixServer.put_response(
        port,
        {"GET", ~r{^/_matrix/federation/v1/query/directory}},
        200,
        %{"room_id" => remote_room_id, "servers" => [server_name]}
      )

      path_alias = full_alias |> URI.encode() |> String.replace("#", "%23")
      authed(alice.token) |> jp("/_matrix/client/v3/join/#{path_alias}", %{})

      [directory_request] =
        Enum.filter(AxonFederation.FakeRemoteMatrixServer.requests(port), fn r ->
          r.path == "/_matrix/federation/v1/query/directory"
        end)

      assert URI.decode_query(directory_request.query_string) == %{"room_alias" => full_alias}
    end
  end

  defp get_state_event(token, room_id, type) do
    conn = authed(token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/#{type}?format=event")
    {conn.status, decode(conn)}
  end

  describe "createRoom power_level_content_override" do
    test "is merged into the room's initial m.room.power_levels event" do
      alice = register("alice_plco1_#{System.unique_integer([:positive])}")
      bob = register("bob_plco1_#{System.unique_integer([:positive])}")

      room_id =
        create_room(alice.token, %{
          "room_version" => "12",
          "invite" => [bob.user_id],
          "power_level_content_override" => %{"users" => %{bob.user_id => 100}}
        })

      {200, pl_event} = get_state_event(alice.token, room_id, "m.room.power_levels")
      assert pl_event["content"]["users"] == %{bob.user_id => 100}
    end

    test "v12: an override naming the room creator in users is rejected with 400, room still unusable/not returned" do
      alice = register("alice_plco2_#{System.unique_integer([:positive])}")
      bob = register("bob_plco2_#{System.unique_integer([:positive])}")

      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/createRoom", %{
          "room_version" => "12",
          "invite" => [bob.user_id],
          "power_level_content_override" => %{"users" => %{alice.user_id => 100}}
        })

      assert conn.status == 400
    end

    test "pre-v12: an override with a users map that excludes the creator is rejected with 400" do
      alice = register("alice_plco3_#{System.unique_integer([:positive])}")
      bob = register("bob_plco3_#{System.unique_integer([:positive])}")

      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/createRoom", %{
          "power_level_content_override" => %{"users" => %{bob.user_id => 100}}
        })

      assert conn.status == 400
    end
  end

  describe "createRoom room v12 defaults (MSC4289)" do
    test "m.room.tombstone defaults to power level 150, not 100" do
      alice = register("alice_v12tomb_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"room_version" => "12"})

      {200, pl_event} = get_state_event(alice.token, room_id, "m.room.power_levels")
      assert pl_event["content"]["events"]["m.room.tombstone"] == 150
    end
  end

  describe "createRoom trusted_private_chat + is_direct (MSC4289 additional_creators)" do
    test "invitees become additional_creators in a v12 DM" do
      alice = register("alice_dm1_#{System.unique_integer([:positive])}")
      bob = register("bob_dm1_#{System.unique_integer([:positive])}")

      room_id =
        create_room(alice.token, %{
          "room_version" => "12",
          "preset" => "trusted_private_chat",
          "is_direct" => true,
          "invite" => [bob.user_id]
        })

      {200, create_event} = get_state_event(alice.token, room_id, "m.room.create")
      assert create_event["content"]["additional_creators"] == [bob.user_id]
    end
  end

  describe "upgrade additional_creators (MSC4289)" do
    test "additional_creators is accepted and appears on the new room's create event" do
      alice = register("alice_up1_#{System.unique_integer([:positive])}")
      bob = register("bob_up1_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/upgrade", %{
          "new_version" => "12",
          "additional_creators" => [bob.user_id]
        })

      assert conn.status == 200
      new_room_id = decode(conn)["replacement_room"]

      {200, create_event} = get_state_event(alice.token, new_room_id, "m.room.create")
      assert create_event["content"]["additional_creators"] == [bob.user_id]

      # The upgrader (new primary creator) and the new additional creator
      # must both be absent from the copied power_levels.users map (rule
      # 10.4 — creators are never listed there).
      {200, pl_event} = get_state_event(alice.token, new_room_id, "m.room.power_levels")
      refute Map.has_key?(pl_event["content"]["users"], alice.user_id)
      refute Map.has_key?(pl_event["content"]["users"], bob.user_id)
    end

    test "a malformed additional_creators entry is rejected with 400" do
      alice = register("alice_up2_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/upgrade", %{
          "new_version" => "12",
          "additional_creators" => ["not-a-user-id"]
        })

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_INVALID_PARAM"
    end

    test "additional_creators on an upgrade to a non-v12 version is rejected with 400" do
      alice = register("alice_up3_#{System.unique_integer([:positive])}")
      bob = register("bob_up3_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/upgrade", %{
          "new_version" => "10",
          "additional_creators" => [bob.user_id]
        })

      assert conn.status == 400
    end
  end
end
