defmodule AxonWeb.Phase9EphemeralTest do
  @moduledoc """
  Regression tests for Phase 9 (federation EDU & real-time parity):

    - Typing indicators, previously a complete no-op stub (PUT
      /rooms/:room_id/typing/:user_id acknowledged and discarded), now
      track real per-room state, surface via /sync, and federate as
      m.typing EDUs both ways.
    - Read receipts previously had no PubSub wake at all (unlike to-device/
      device-list/account-data, fixed in Phase 8) and were gated behind a
      room having a *new timeline event* to even appear in an incremental
      sync — a receipt-only change in an otherwise-quiet room was silently
      dropped until something else happened in that room. Both are fixed
      here, and receipts now federate as m.receipt EDUs (m.read only, never
      m.read.private).
    - Presence changes federate as m.presence EDUs to servers sharing a
      room with the user, without flooding on every request (only on an
      actual state transition, not the "keep last_active_ts fresh" touch
      that happens on every authenticated call).
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import AxonWeb.TestHelpers

  alias AxonCore.Repo
  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}
  alias AxonRoom.RoomProcess
  alias AxonSync.{Presence, Typing}

  @port 19_100
  @server_name "fake-phase9.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
    :ok
  end

  defp sync_once(token, since \\ nil, timeout \\ nil) do
    query =
      [since && "since=#{since}", timeout && "timeout=#{timeout}"]
      |> Enum.filter(& &1)
      |> Enum.join("&")

    path = if query == "", do: "/_matrix/client/v3/sync", else: "/_matrix/client/v3/sync?#{query}"
    conn = authed(token) |> get(path)
    assert conn.status == 200
    decode(conn)
  end

  defp remote_user(prefix), do: "@#{prefix}_#{System.unique_integer([:positive])}:#{@server_name}"

  defp signed_remote_event(fields) do
    FakeRemoteMatrixServer.sign_event(@port, Map.merge(%{"hashes" => %{"sha256" => "x"}}, fields))
  end

  # Mirrors federation_controller_test.exs's helper: apply_remote_event/2 is
  # the real path a federated join takes (a local self-join can't be seeded
  # on someone else's behalf).
  defp join_remote_member(room_id, member_user_id) do
    {last_event_id, depth} = RoomProcess.get_position(room_id)

    pdu =
      signed_remote_event(%{
        "event_id" => "$seedjoin_#{System.unique_integer([:positive])}",
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

  defp wait_until(deadline_ms, fun) do
    case fun.() do
      {:ok, value} ->
        value

      :error ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          flunk("condition not met before deadline")
        else
          Process.sleep(20)
          wait_until(deadline_ms, fun)
        end
    end
  end

  defp outbound_edu_requests(edu_type) do
    FakeRemoteMatrixServer.requests(@port)
    |> Enum.filter(&String.starts_with?(&1.path, "/_matrix/federation/v1/send/"))
    |> Enum.flat_map(fn req -> req.body["edus"] || [] end)
    |> Enum.filter(&(&1["edu_type"] == edu_type))
  end

  # ---------------------------------------------------------------------------
  # Typing
  # ---------------------------------------------------------------------------

  describe "typing indicators" do
    test "start/stop is reflected in /sync ephemeral for the room, and wakes a long-poll" do
      alice = register("alice_typing_#{System.unique_integer([:positive])}")
      bob = register("bob_typing_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      assert authed(bob.token)
             |> jp("/_matrix/client/v3/join/#{room_id}", %{})
             |> Map.get(:status) == 200

      since = sync_once(bob.token)["next_batch"]

      task =
        Task.async(fn ->
          started_at = System.monotonic_time(:millisecond)
          body = sync_once(bob.token, since, 5_000)
          {body, System.monotonic_time(:millisecond) - started_at}
        end)

      Process.sleep(200)

      conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/rooms/#{room_id}/typing/#{alice.user_id}", %{
          "typing" => true,
          "timeout" => 30_000
        })

      assert conn.status == 200

      {body, elapsed_ms} = Task.await(task, 6_000)
      assert elapsed_ms < 2_000

      room_data = body["rooms"]["join"][room_id]
      typing_events = Enum.filter(room_data["ephemeral"]["events"], &(&1["type"] == "m.typing"))
      assert [%{"content" => %{"user_ids" => [typing_user]}}] = typing_events
      assert typing_user == alice.user_id

      stop_conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/rooms/#{room_id}/typing/#{alice.user_id}", %{"typing" => false})

      assert stop_conn.status == 200

      body2 = sync_once(bob.token, body["next_batch"])

      [typing_event2] =
        Enum.filter(
          body2["rooms"]["join"][room_id]["ephemeral"]["events"],
          &(&1["type"] == "m.typing")
        )

      assert typing_event2["content"]["user_ids"] == []
    end

    test "rejects setting another user's typing state, and non-members" do
      alice = register("alice_typing_perm_#{System.unique_integer([:positive])}")
      bob = register("bob_typing_perm_#{System.unique_integer([:positive])}")
      outsider = register("outsider_typing_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      spoof_conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/rooms/#{room_id}/typing/#{bob.user_id}", %{"typing" => true})

      assert spoof_conn.status == 403

      non_member_conn =
        authed(outsider.token)
        |> jpu("/_matrix/client/v3/rooms/#{room_id}/typing/#{outsider.user_id}", %{
          "typing" => true
        })

      assert non_member_conn.status == 403
    end

    test "expires after its timeout without an explicit stop" do
      room_id = "!typing_expiry_#{System.unique_integer([:positive])}:localhost"
      Typing.start(room_id, "@expiring:localhost", 50)
      assert "@expiring:localhost" in Typing.typing_user_ids(room_id)

      Process.sleep(100)
      assert Typing.typing_user_ids(room_id) == []
    end

    test "PUT typing relays an m.typing EDU to a remote room member, and an inbound EDU updates local state" do
      alice = register("alice_typing_fed_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      remote_member = remote_user("bob")
      join_remote_member(room_id, remote_member)

      conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/rooms/#{room_id}/typing/#{alice.user_id}", %{
          "typing" => true,
          "timeout" => 30_000
        })

      assert conn.status == 200

      [edu] =
        wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
          case outbound_edu_requests("m.typing") do
            [] -> :error
            edus -> {:ok, edus}
          end
        end)

      assert edu["content"]["room_id"] == room_id
      assert edu["content"]["user_id"] == alice.user_id
      assert edu["content"]["typing"] == true

      # Inbound: the remote member starts typing too.
      inbound_edu = %{
        "edu_type" => "m.typing",
        "content" => %{
          "room_id" => room_id,
          "user_id" => remote_member,
          "typing" => true,
          "timeout" => 30_000
        }
      }

      txn_id = "txn_#{System.unique_integer([:positive])}"
      path = "/_matrix/federation/v1/send/#{txn_id}"
      body = %{"pdus" => [], "edus" => [inbound_edu]}
      header = FakeRemoteMatrixServer.sign_request(@port, "PUT", path, body)

      inbound_conn =
        build_conn()
        |> put_req_header("authorization", header)
        |> put_req_header("content-type", "application/json")
        |> put(path, Jason.encode!(body))

      assert inbound_conn.status == 200
      assert remote_member in Typing.typing_user_ids(room_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Receipts
  # ---------------------------------------------------------------------------

  describe "read receipts" do
    test "a receipt-only change (no new timeline event) wakes a long-poll and appears in the room's join entry" do
      alice = register("alice_receipt_#{System.unique_integer([:positive])}")
      bob = register("bob_receipt_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})

      assert authed(bob.token)
             |> jp("/_matrix/client/v3/join/#{room_id}", %{})
             |> Map.get(:status) == 200

      event_id =
        send_event(alice.token, room_id, "m.room.message", %{
          "msgtype" => "m.text",
          "body" => "hi"
        })

      # Baseline sync — both parties are caught up on the message above.
      sync_once(alice.token)
      since = sync_once(bob.token)["next_batch"]

      task =
        Task.async(fn ->
          started_at = System.monotonic_time(:millisecond)
          body = sync_once(bob.token, since, 5_000)
          {body, System.monotonic_time(:millisecond) - started_at}
        end)

      Process.sleep(200)

      receipt_conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read/#{event_id}", %{})

      assert receipt_conn.status == 200

      {body, elapsed_ms} = Task.await(task, 6_000)
      assert elapsed_ms < 2_000

      room_data = body["rooms"]["join"][room_id]
      assert room_data != nil
      assert room_data["timeline"]["events"] == []

      [receipt_event] =
        Enum.filter(room_data["ephemeral"]["events"], &(&1["type"] == "m.receipt"))

      assert get_in(receipt_event, ["content", event_id, "m.read", alice.user_id]) != nil
    end

    test "m.read federates to a remote room member as an m.receipt EDU; m.read.private does not" do
      alice = register("alice_receipt_fed_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      remote_member = remote_user("bob")
      join_remote_member(room_id, remote_member)

      event_id =
        send_event(alice.token, room_id, "m.room.message", %{
          "msgtype" => "m.text",
          "body" => "hi"
        })

      private_conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read.private/#{event_id}", %{})

      assert private_conn.status == 200

      public_conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read/#{event_id}", %{})

      assert public_conn.status == 200

      [edu] =
        wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
          case outbound_edu_requests("m.receipt") do
            [] -> :error
            edus -> {:ok, edus}
          end
        end)

      assert get_in(edu, ["content", room_id, "m.read", alice.user_id, "event_ids"]) == [event_id]
    end

    test "an inbound m.receipt EDU is stored and surfaced in the local recipient's sync" do
      alice = register("alice_receipt_in_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      remote_member = remote_user("bob")
      join_remote_member(room_id, remote_member)

      event_id =
        send_event(alice.token, room_id, "m.room.message", %{
          "msgtype" => "m.text",
          "body" => "hi"
        })

      edu = %{
        "edu_type" => "m.receipt",
        "content" => %{
          room_id => %{
            "m.read" => %{
              remote_member => %{
                "data" => %{"ts" => System.os_time(:millisecond)},
                "event_ids" => [event_id]
              }
            }
          }
        }
      }

      txn_id = "txn_#{System.unique_integer([:positive])}"
      path = "/_matrix/federation/v1/send/#{txn_id}"
      body = %{"pdus" => [], "edus" => [edu]}
      header = FakeRemoteMatrixServer.sign_request(@port, "PUT", path, body)

      conn =
        build_conn()
        |> put_req_header("authorization", header)
        |> put_req_header("content-type", "application/json")
        |> put(path, Jason.encode!(body))

      assert conn.status == 200

      count =
        Repo.aggregate(
          from(r in "receipts", where: r.room_id == ^room_id and r.user_id == ^remote_member),
          :count
        )

      assert count == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Presence
  # ---------------------------------------------------------------------------

  describe "presence federation" do
    test "an explicit presence change relays an m.presence EDU to a remote room member" do
      alice = register("alice_presence_fed_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      remote_member = remote_user("bob")
      join_remote_member(room_id, remote_member)

      conn =
        authed(alice.token)
        |> jpu("/_matrix/client/v3/presence/#{alice.user_id}/status", %{
          "presence" => "unavailable",
          "status_msg" => "be right back"
        })

      assert conn.status == 200

      [edu] =
        wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
          case outbound_edu_requests("m.presence") do
            [] -> :error
            edus -> {:ok, edus}
          end
        end)

      [push] = edu["content"]["push"]
      assert push["user_id"] == alice.user_id
      assert push["presence"] == "unavailable"
      assert push["status_msg"] == "be right back"
    end

    test "an inbound m.presence EDU for a known remote user updates local presence state" do
      alice = register("alice_presence_in_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      remote_member = remote_user("bob")
      join_remote_member(room_id, remote_member)

      edu = %{
        "edu_type" => "m.presence",
        "content" => %{
          "push" => [
            %{
              "user_id" => remote_member,
              "presence" => "online",
              "last_active_ago" => 1_000,
              "status_msg" => "remote status"
            }
          ]
        }
      }

      txn_id = "txn_#{System.unique_integer([:positive])}"
      path = "/_matrix/federation/v1/send/#{txn_id}"
      body = %{"pdus" => [], "edus" => [edu]}
      header = FakeRemoteMatrixServer.sign_request(@port, "PUT", path, body)

      conn =
        build_conn()
        |> put_req_header("authorization", header)
        |> put_req_header("content-type", "application/json")
        |> put(path, Jason.encode!(body))

      assert conn.status == 200

      presence = Presence.get(remote_member)
      assert presence["presence"] == "online"
      assert presence["status_msg"] == "remote status"
    end

    test "an inbound m.presence EDU for an unrelated (unknown) user is ignored" do
      unrelated_user = remote_user("stranger")

      edu = %{
        "edu_type" => "m.presence",
        "content" => %{"push" => [%{"user_id" => unrelated_user, "presence" => "online"}]}
      }

      txn_id = "txn_#{System.unique_integer([:positive])}"
      path = "/_matrix/federation/v1/send/#{txn_id}"
      body = %{"pdus" => [], "edus" => [edu]}
      header = FakeRemoteMatrixServer.sign_request(@port, "PUT", path, body)

      conn =
        build_conn()
        |> put_req_header("authorization", header)
        |> put_req_header("content-type", "application/json")
        |> put(path, Jason.encode!(body))

      assert conn.status == 200
      assert Presence.get(unrelated_user)["presence"] == "offline"
    end
  end
end
