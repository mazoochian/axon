defmodule AxonWeb.TimestampToEventTest do
  @moduledoc """
  GET /_matrix/client/v1/rooms/:room_id/timestamp_to_event ("jump to date").

  Mirrors Complement's `TestJumpToDateEndpoint`: closest event in each
  direction, nothing found beyond either end of the room's history, the
  topological tie-break when every event shares a timestamp, and the
  membership gate that applies even to a public room.
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AxonCore.EventStore

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
end
