defmodule AxonWeb.TimestampToEventTest do
  @moduledoc """
  GET /_matrix/client/v1/rooms/:room_id/timestamp_to_event ("jump to date").

  Mirrors Complement's `TestJumpToDateEndpoint`: closest event in each
  direction, nothing found beyond either end of the room's history, the
  topological tie-break when every event shares a timestamp, and the
  membership gate that applies even to a public room. The "federation"
  describe block below covers the other half of that same Complement test
  — Complement's `remoteCharlie` scenarios, where the requesting server
  never held the target event locally at all and has to ask a resident
  peer (`AxonFederation.TimestampToEvent`, `AxonWeb.FederationController.timestamp_to_event/2`).
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AxonCore.EventStore
  alias AxonFederation.FakeRemoteMatrixServer
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
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token, opts \\ %{"preset" => "public_chat"}) do
    conn =
      authed(token)
      |> put_req_header("content-type", "application/json")
      |> post("/_matrix/client/v3/createRoom", Jason.encode!(opts))

    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp send_message(token, room_id, body \\ "hi") do
    txn = "txn_#{System.unique_integer([:positive])}"

    conn =
      authed(token)
      |> put_req_header("content-type", "application/json")
      |> put(
        "/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn}",
        Jason.encode!(%{"msgtype" => "m.text", "body" => body})
      )

    assert conn.status == 200
    event_id = decode(conn)["event_id"]
    {:ok, event} = EventStore.get_event(event_id)
    {event_id, event.origin_server_ts}
  end

  # ---- federation-fallback helpers (mirrors AxonWeb.FederationControllerTest's
  # pattern: a real signed counterparty via AxonFederation.FakeRemoteMatrixServer) ----

  defp signed_remote_event(port, fields) do
    FakeRemoteMatrixServer.sign_event(port, Map.merge(%{"hashes" => %{"sha256" => "x"}}, fields))
  end

  defp remote_user(port, prefix),
    do:
      "@#{prefix}_#{System.unique_integer([:positive])}:#{FakeRemoteMatrixServer.server_name(port)}"

  # Seeds a remote member as an already-joined resident of the room, the
  # same way AxonWeb.FederationControllerTest does — a local self-join
  # can't target another user, so this goes through the real inbound path
  # (RoomProcess.apply_remote_event/2) a federated join would take. Once
  # seeded, AxonCore.EventStore.remote_servers_for_room/1 names this port's
  # server as one of the room's residents, which is what makes
  # AxonFederation.TimestampToEvent.find/3 ask it in the first place.
  defp join_remote_member(port, room_id, member_user_id) do
    {last_event_id, depth} = RoomProcess.get_position(room_id)

    pdu =
      signed_remote_event(port, %{
        "event_id" => "$seedjoin_#{unique()}",
        "room_id" => room_id,
        "type" => "m.room.member",
        "state_key" => member_user_id,
        "sender" => member_user_id,
        "content" => %{"membership" => "join"},
        "depth" => depth + 1,
        "prev_events" => if(last_event_id, do: [last_event_id], else: []),
        "origin_server_ts" => System.os_time(:millisecond)
      })

    {:ok, _} = RoomProcess.apply_remote_event(room_id, pdu)
  end

  defp jump(token, room_id, ts, dir) do
    authed(token)
    |> get("/_matrix/client/v1/rooms/#{room_id}/timestamp_to_event?ts=#{ts}&dir=#{dir}")
  end

  defp unique, do: System.unique_integer([:positive])

  describe "finding the closest event" do
    setup do
      alice = register("alice_ts_#{unique()}")
      room_id = create_room(alice.token)

      # Space the sends out so each message lands in its own millisecond —
      # otherwise "the event before B" and "the event after B" are the same
      # tied set and the direction assertions below say nothing.
      {a_id, a_ts} = send_message(alice.token, room_id, "first")
      Process.sleep(10)
      {b_id, b_ts} = send_message(alice.token, room_id, "second")
      Process.sleep(10)
      {c_id, c_ts} = send_message(alice.token, room_id, "third")

      %{
        alice: alice,
        room_id: room_id,
        a: {a_id, a_ts},
        b: {b_id, b_ts},
        c: {c_id, c_ts}
      }
    end

    test "an exact timestamp resolves to that event in both directions", ctx do
      {b_id, b_ts} = ctx.b

      conn = jump(ctx.alice.token, ctx.room_id, b_ts, "f")
      assert conn.status == 200
      assert %{"event_id" => ^b_id, "origin_server_ts" => ^b_ts} = decode(conn)

      conn = jump(ctx.alice.token, ctx.room_id, b_ts, "b")
      assert conn.status == 200
      assert %{"event_id" => ^b_id} = decode(conn)
    end

    test "looking forwards finds the next event after the timestamp", ctx do
      {_b_id, b_ts} = ctx.b
      {c_id, _c_ts} = ctx.c

      conn = jump(ctx.alice.token, ctx.room_id, b_ts + 1, "f")
      assert conn.status == 200
      assert %{"event_id" => ^c_id} = decode(conn)
    end

    test "looking backwards finds the previous event before the timestamp", ctx do
      {a_id, _a_ts} = ctx.a
      {_b_id, b_ts} = ctx.b

      conn = jump(ctx.alice.token, ctx.room_id, b_ts - 1, "b")
      assert conn.status == 200
      assert %{"event_id" => ^a_id} = decode(conn)
    end

    test "dir defaults to f when omitted", ctx do
      {b_id, b_ts} = ctx.b

      conn =
        authed(ctx.alice.token)
        |> get("/_matrix/client/v1/rooms/#{ctx.room_id}/timestamp_to_event?ts=#{b_ts}")

      assert conn.status == 200
      assert %{"event_id" => ^b_id} = decode(conn)
    end

    test "finds nothing before the earliest timestamp", ctx do
      conn = jump(ctx.alice.token, ctx.room_id, 1, "b")
      assert conn.status == 404
      assert %{"errcode" => "M_NOT_FOUND"} = decode(conn)
    end

    test "finds nothing after the latest timestamp", ctx do
      {_c_id, c_ts} = ctx.c
      conn = jump(ctx.alice.token, ctx.room_id, c_ts + 60_000, "f")
      assert conn.status == 404
      assert %{"errcode" => "M_NOT_FOUND"} = decode(conn)
    end
  end

  describe "ties on origin_server_ts break topologically" do
    test "forwards takes the earliest tied event, backwards the latest" do
      alice = register("alice_tie_#{unique()}")
      room_id = create_room(alice.token)

      {first_id, _} = send_message(alice.token, room_id, "same-ms first")
      {_, _} = send_message(alice.token, room_id, "same-ms second")
      {last_id, _} = send_message(alice.token, room_id, "same-ms third")

      # Force the whole room onto a single timestamp, which is what a bridged
      # or imported history looks like. Direction then has to be resolved by
      # stream_ordering alone.
      shared_ts = 1_500_000_000_000
      AxonCore.Repo.update_all(
        from(e in "events", where: e.room_id == ^room_id),
        set: [origin_server_ts: shared_ts]
      )

      forward = EventStore.find_event_by_timestamp(room_id, shared_ts, "f")
      backward = EventStore.find_event_by_timestamp(room_id, shared_ts, "b")

      # Forwards lands on the room's very first event (the create event, which
      # precedes every message), backwards on the last message sent.
      assert forward.stream_ordering < backward.stream_ordering
      assert backward.event_id == last_id
      refute forward.event_id == last_id

      # Sanity: the first message is somewhere between the two ends.
      {:ok, first} = EventStore.get_event(first_id)
      assert forward.stream_ordering <= first.stream_ordering
      assert first.stream_ordering <= backward.stream_ordering
    end
  end

  describe "access control and parameter validation" do
    test "a non-member of a public room is refused" do
      alice = register("alice_acl_#{unique()}")
      bob = register("bob_acl_#{unique()}")
      room_id = create_room(alice.token)
      {_id, ts} = send_message(alice.token, room_id)

      conn = jump(bob.token, room_id, ts, "f")
      assert conn.status == 403
      assert %{"errcode" => "M_FORBIDDEN"} = decode(conn)
    end

    test "a missing ts is a 400" do
      alice = register("alice_p1_#{unique()}")
      room_id = create_room(alice.token)

      conn = authed(alice.token) |> get("/_matrix/client/v1/rooms/#{room_id}/timestamp_to_event")
      assert conn.status == 400
      assert %{"errcode" => "M_MISSING_PARAM"} = decode(conn)
    end

    test "a non-integer ts is a 400" do
      alice = register("alice_p2_#{unique()}")
      room_id = create_room(alice.token)

      conn = jump(alice.token, room_id, "yesterday", "f")
      assert conn.status == 400
      assert %{"errcode" => "M_INVALID_PARAM"} = decode(conn)
    end

    test "an unknown dir is a 400" do
      alice = register("alice_p3_#{unique()}")
      room_id = create_room(alice.token)

      conn = jump(alice.token, room_id, 1_500_000_000_000, "sideways")
      assert conn.status == 400
      assert %{"errcode" => "M_INVALID_PARAM"} = decode(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Federation fallback (Complement's TestJumpToDateEndpoint "federation"
  # subtests, room_timestamp_to_event_test.go from ~line 168): a member who
  # joined too late for the local server to hold history around a given
  # timestamp — the room's create event is always present locally (it's
  # part of current state), so the "local search finds nothing" case that
  # actually exercises the fallback is `dir=b` with a `ts` older than
  # everything this server holds, e.g. an imported/bridged event backdated
  # to before the room even existed here.
  # ---------------------------------------------------------------------------

  describe "federation fallback" do
    @port 19_400
    @server_name "fake-ts2e.test"

    setup do
      start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})

      Application.put_env(:axon_federation, :server_overrides, %{
        @server_name => "http://127.0.0.1:#{@port}"
      })

      on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)

      alice = register("alice_fed_#{unique()}")
      room_id = create_room(alice.token)
      bob = remote_user(@port, "bob")
      join_remote_member(@port, room_id, bob)

      %{alice: alice, room_id: room_id, bob: bob}
    end

    test "finds an event via federation that the local server never held, and backfills it so /context works afterwards",
         %{alice: alice, room_id: room_id, bob: bob} do
      old_ts = 1_000
      imported_event_id = "$imported_#{unique()}"

      pdu =
        signed_remote_event(@port, %{
          "event_id" => imported_event_id,
          "room_id" => room_id,
          "type" => "m.room.message",
          # sender must be an already-joined member (bob) — AuthRules
          # rejects a message from anyone else, same as a live PDU would.
          "sender" => bob,
          "content" => %{"msgtype" => "m.text", "body" => "an old imported message"},
          "depth" => 1,
          "prev_events" => [],
          "origin_server_ts" => old_ts
        })

      FakeRemoteMatrixServer.put_response(
        @port,
        {"GET", ~r{^/_matrix/federation/v1/timestamp_to_event/}},
        200,
        %{"event_id" => imported_event_id, "origin_server_ts" => old_ts}
      )

      FakeRemoteMatrixServer.put_response(
        @port,
        {"GET", ~r{^/_matrix/federation/v1/event/}},
        200,
        %{
          "origin" => @server_name,
          "origin_server_ts" => old_ts,
          "pdus" => [pdu]
        }
      )

      # Nothing locally reaches back this far (the room's own create event
      # postdates old_ts), so this can only succeed via the federation
      # fallback.
      conn = jump(alice.token, room_id, old_ts, "b")
      assert conn.status == 200
      assert %{"event_id" => ^imported_event_id, "origin_server_ts" => ^old_ts} = decode(conn)

      # Per spec, the server "should try to backfill this event" once it
      # learns of it — confirm it's now genuinely stored, not just relayed,
      # which is what lets a client immediately paginate /context or
      # /messages around it afterwards.
      assert {:ok, stored} = EventStore.get_event(imported_event_id)
      assert stored.room_id == room_id
      assert stored.origin_server_ts == old_ts
    end

    test "falls back to 404 when the resident server has nothing for that timestamp either", %{
      alice: alice,
      room_id: room_id
    } do
      old_ts = 2_000

      FakeRemoteMatrixServer.put_response(
        @port,
        {"GET", ~r{^/_matrix/federation/v1/timestamp_to_event/}},
        404,
        %{"errcode" => "M_NOT_FOUND", "error" => "no event that far back"}
      )

      conn = jump(alice.token, room_id, old_ts, "b")
      assert conn.status == 404
      assert %{"errcode" => "M_NOT_FOUND"} = decode(conn)
    end

    test "falls back to 404 when the resident server is unreachable", %{
      alice: alice,
      room_id: room_id
    } do
      old_ts = 3_000
      # Point the fake server's name at a port nothing is listening on.
      dead_port = @port + 1

      Application.put_env(:axon_federation, :server_overrides, %{
        @server_name => "http://127.0.0.1:#{dead_port}"
      })

      conn = jump(alice.token, room_id, old_ts, "b")
      assert conn.status == 404
      assert %{"errcode" => "M_NOT_FOUND"} = decode(conn)
    end

    test "does not trust (or store) an event whose signature fails verification", %{
      alice: alice,
      room_id: room_id,
      bob: bob
    } do
      old_ts = 4_000
      bad_event_id = "$badsig_#{unique()}"

      # A PDU claiming to be signed by @server_name, but actually signed by
      # a different keypair (a second fake server started just to hold an
      # unrelated key) — the shape axon would see from an impostor, or a
      # server whose key rotated out from under a stale response.
      other_port = @port + 2
      start_supervised!({FakeRemoteMatrixServer, port: other_port, server_name: "impostor.test"})

      forged_pdu =
        signed_remote_event(other_port, %{
          "event_id" => bad_event_id,
          "room_id" => room_id,
          "type" => "m.room.message",
          "sender" => bob,
          "content" => %{"msgtype" => "m.text", "body" => "forged"},
          "depth" => 1,
          "prev_events" => [],
          "origin_server_ts" => old_ts
        })

      FakeRemoteMatrixServer.put_response(
        @port,
        {"GET", ~r{^/_matrix/federation/v1/timestamp_to_event/}},
        200,
        %{"event_id" => bad_event_id, "origin_server_ts" => old_ts}
      )

      FakeRemoteMatrixServer.put_response(
        @port,
        {"GET", ~r{^/_matrix/federation/v1/event/}},
        200,
        %{"origin" => @server_name, "origin_server_ts" => old_ts, "pdus" => [forged_pdu]}
      )

      conn = jump(alice.token, room_id, old_ts, "b")
      assert conn.status == 404
      assert %{"errcode" => "M_NOT_FOUND"} = decode(conn)
      assert EventStore.get_event(bad_event_id) == {:error, :not_found}
    end
  end
end
