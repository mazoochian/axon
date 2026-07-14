defmodule AxonWeb.E2EEDeliveryTest do
  @moduledoc """
  Regression tests for Phase 8 (E2EE reliability & cross-server delivery):

    - sendToDevice must wake a long-polling /sync immediately, not only once
      the client's own timeout elapses (previously dead code — nothing ever
      broadcast `{:to_device, _}`, so every real (nonzero-timeout) long-poll
      client saw multi-second-to-30s delivery delay for room keys and
      verification messages).
    - device_lists.changed must fire when a user newly shares a room with
      someone, even if neither party's keys have changed since — previously
      only key upload/cross-signing bumped this, so a client that trusts the
      server's signal (rather than deriving it from room membership itself)
      never learned to query/verify a fresh room-mate's devices.
    - device_lists.left must fire when the last shared room with a user is
      left — previously hardcoded to `[]`.
    - sendToDevice must relay to users on other homeservers as an
      `m.direct_to_device` federation EDU instead of silently dropping the
      message into the local-only `to_device_messages` table.

  Every existing /sync test in this suite uses `timeout=0` (or omits
  `timeout`), which takes the short-poll branch and never exercises
  `AxonSync.Manager.wait_loop/3` at all — that's what let the to-device wake
  bug go unnoticed. The tests below deliberately use a nonzero timeout to
  close that gap.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}

  @port 19_050
  @server_name "fake-e2ee-delivery.test"

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

  defp send_to_device(token, event_type, messages) do
    txn_id = "txn_#{System.unique_integer([:positive])}"

    authed(token)
    |> jpu("/_matrix/client/v3/sendToDevice/#{event_type}/#{txn_id}", %{"messages" => messages})
  end

  # The EDU fan-out happens in a Task spawned asynchronously by
  # AxonWeb.FederationFanout's handle_info, after this test's own process has
  # already moved on — so it may not have run (or even been spawned) yet by
  # the time we check. Poll instead of asserting immediately.
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

  describe "to-device wake-up" do
    test "sendToDevice broadcasts {:to_device, user_id} on the target's PubSub channel" do
      alice = register("alice_wake_#{System.unique_integer([:positive])}")
      bob = register("bob_wake_#{System.unique_integer([:positive])}")

      Phoenix.PubSub.subscribe(Axon.PubSub, "user:#{bob.user_id}")

      conn =
        send_to_device(alice.token, "m.room_key", %{
          bob.user_id => %{bob.device_id => %{"session_key" => "s3kr3t"}}
        })

      assert conn.status == 200
      assert_receive {:to_device, bob_user_id}, 1000
      assert bob_user_id == bob.user_id
    end

    test "a long-polling /sync with a nonzero timeout returns as soon as a to-device message arrives" do
      alice = register("alice_longpoll_#{System.unique_integer([:positive])}")
      bob = register("bob_longpoll_#{System.unique_integer([:positive])}")

      # Establish bob's baseline so the poll below is a real incremental sync.
      since = sync_once(bob.token)["next_batch"]

      task =
        Task.async(fn ->
          started_at = System.monotonic_time(:millisecond)
          body = sync_once(bob.token, since, 5_000)
          {body, System.monotonic_time(:millisecond) - started_at}
        end)

      # Give the poll a moment to actually start blocking in wait_loop/3
      # before sending, so this isn't just measuring the pre-check race.
      Process.sleep(200)

      conn =
        send_to_device(alice.token, "m.room_key", %{
          bob.user_id => %{bob.device_id => %{"session_key" => "s3kr3t"}}
        })

      assert conn.status == 200

      {body, elapsed_ms} = Task.await(task, 6_000)

      # Woken well before the 5s timeout — bounds out the old "block for the
      # full client timeout" bug without being a tight, flaky bound.
      assert elapsed_ms < 2_000

      [event] = body["to_device"]["events"]
      assert event["sender"] == alice.user_id
      assert event["content"]["session_key"] == "s3kr3t"
    end
  end

  describe "device_lists.changed / left on room membership" do
    test "reports a user as changed when a room is newly shared with them, even if their keys never changed" do
      alice = register("alice_dlnew_#{System.unique_integer([:positive])}")
      bob = register("bob_dlnew_#{System.unique_integer([:positive])}")

      # Bob's keys are uploaded well before he ever shares a room with alice.
      authed(bob.token)
      |> jp("/_matrix/client/v3/keys/upload", %{
        "device_keys" => %{
          "user_id" => bob.user_id,
          "device_id" => bob.device_id,
          "algorithms" => ["m.megolm.v1.aes-sha2"],
          "keys" => %{"ed25519:#{bob.device_id}" => "ed_#{bob.device_id}"},
          "signatures" => %{}
        }
      })
      |> then(fn conn -> assert conn.status == 200 end)

      # Alice's baseline sync predates any shared room with bob — bob's old
      # key-upload row must NOT be what surfaces him as changed here.
      alice_since = sync_once(alice.token)["next_batch"]

      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join_conn = authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
      assert join_conn.status == 200

      alice_next = sync_once(alice.token, alice_since)
      assert bob.user_id in alice_next["device_lists"]["changed"]
    end

    test "reports a user as left when the only room shared with them is left, but not while another shared room remains" do
      alice = register("alice_dlleft_#{System.unique_integer([:positive])}")
      bob = register("bob_dlleft_#{System.unique_integer([:positive])}")

      room_a = create_room(alice.token, %{"preset" => "public_chat"})
      room_b = create_room(alice.token, %{"preset" => "public_chat"})

      assert authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_a}", %{}) |> Map.get(:status) == 200
      assert authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_b}", %{}) |> Map.get(:status) == 200

      alice_since = sync_once(alice.token)["next_batch"]

      # Bob leaves room_a but still shares room_b with alice — must not be
      # reported as "left" yet.
      leave_conn = authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_a}/leave", %{})
      assert leave_conn.status == 200

      alice_mid = sync_once(alice.token, alice_since)
      refute bob.user_id in alice_mid["device_lists"]["left"]

      # Bob leaves room_b too — no shared room remains, must now be "left".
      leave_conn2 = authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_b}/leave", %{})
      assert leave_conn2.status == 200

      alice_next = sync_once(alice.token, alice_mid["next_batch"])
      assert bob.user_id in alice_next["device_lists"]["left"]
    end
  end

  describe "cross-server to-device relay (EDUs)" do
    setup do
      start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
      KeyCache.clear()
      Application.put_env(:axon_federation, :server_overrides, %{@server_name => "http://127.0.0.1:#{@port}"})
      on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
      :ok
    end

    test "sendToDevice targeting a remote user relays an m.direct_to_device EDU instead of dropping it" do
      alice = register("alice_edu_out_#{System.unique_integer([:positive])}")
      remote_user = "@bob:#{@server_name}"

      conn =
        send_to_device(alice.token, "m.room_key", %{
          remote_user => %{"REMOTE_DEVICE" => %{"session_key" => "s3kr3t_remote"}}
        })

      assert conn.status == 200

      req =
        wait_until(System.monotonic_time(:millisecond) + 2_000, fn ->
          case FakeRemoteMatrixServer.requests(@port)
               |> Enum.filter(&String.starts_with?(&1.path, "/_matrix/federation/v1/send/")) do
            [req] -> {:ok, req}
            [] -> :error
          end
        end)

      [edu] = req.body["edus"]
      assert edu["edu_type"] == "m.direct_to_device"
      assert edu["content"]["sender"] == alice.user_id
      assert edu["content"]["type"] == "m.room_key"

      assert edu["content"]["messages"][remote_user]["REMOTE_DEVICE"]["session_key"] ==
               "s3kr3t_remote"
    end

    test "an inbound m.direct_to_device EDU is delivered to the local target and wakes their /sync" do
      local_user = register("local_edu_in_#{System.unique_integer([:positive])}")
      remote_sender = "@alice:#{@server_name}"

      edu = %{
        "edu_type" => "m.direct_to_device",
        "content" => %{
          "sender" => remote_sender,
          "type" => "m.room_key",
          "message_id" => "edu_#{System.unique_integer([:positive])}",
          "messages" => %{
            local_user.user_id => %{local_user.device_id => %{"session_key" => "fed3kr3t"}}
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

      sync_body = sync_once(local_user.token)
      [event] = sync_body["to_device"]["events"]
      assert event["sender"] == remote_sender
      assert event["content"]["session_key"] == "fed3kr3t"
    end
  end
end
