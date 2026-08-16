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

  alias AxonCore.KeyStore
  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}
  alias AxonRoom.RoomProcess

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

      assert authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_a}", %{}) |> Map.get(:status) ==
               200

      assert authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_b}", %{}) |> Map.get(:status) ==
               200

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

      Application.put_env(:axon_federation, :server_overrides, %{
        @server_name => "http://127.0.0.1:#{@port}"
      })

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

  # ---------------------------------------------------------------------------
  # Device lists over federation (m.device_list_update EDU) — previously
  # entirely unimplemented in both directions: the literal string
  # "m.device_list_update" appeared nowhere in lib/, so a device change never
  # left this server, and an inbound one from a peer was silently dropped by
  # AxonWeb.FederationController's EDU catch-all. Outbound is
  # AxonFederation.DeviceListFanout (polls device_list_updates, the same log
  # this file's "device_lists.changed / left on room membership" tests read
  # locally, and fans a changed local user's current device list out to
  # every remote server sharing a room with them). Inbound is the
  # `"m.device_list_update"` clause in
  # AxonWeb.FederationController.process_inbound_edu/2, right next to
  # `"m.direct_to_device"` above.
  # ---------------------------------------------------------------------------

  describe "device list updates over federation (m.device_list_update EDU)" do
    setup do
      start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
      KeyCache.clear()

      Application.put_env(:axon_federation, :server_overrides, %{
        @server_name => "http://127.0.0.1:#{@port}"
      })

      on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
      :ok
    end

    defp remote_user_id(prefix),
      do: "@#{prefix}_#{System.unique_integer([:positive])}:#{@server_name}"

    # Seeds a remote member as an already-joined resident of the room —
    # mirrors AxonWeb.FederationControllerTest.join_remote_member/3. A local
    # self-join can't target another user, so this goes through the same
    # inbound path (RoomProcess.apply_remote_event/2) a federated join
    # would take, which is also what makes
    # AxonCore.EventStore.remote_servers_for_user/1 (what
    # AxonFederation.DeviceListFanout asks to find fan-out targets) name
    # this port's server as sharing the room afterwards.
    defp join_remote_member(room_id, member_user_id) do
      {last_event_id, depth} = RoomProcess.get_position(room_id)

      pdu =
        FakeRemoteMatrixServer.sign_event(@port, %{
          "hashes" => %{"sha256" => "x"},
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

    test "a local user's device list change is fanned out as m.device_list_update to a remote room-mate's server" do
      alice = register("alice_dlfed_out_#{System.unique_integer([:positive])}")
      bob = remote_user_id("bob")

      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join_remote_member(room_id, bob)

      # Trigger the same signal every other device-list-changing code path
      # (login, key upload, device rename/delete) already calls —
      # AxonFederation.DeviceListFanout polls this log, it doesn't care
      # which call site produced the row.
      KeyStore.record_device_list_update(alice.user_id)

      req =
        wait_until(System.monotonic_time(:millisecond) + 3_000, fn ->
          FakeRemoteMatrixServer.requests(@port)
          |> Enum.filter(&String.starts_with?(&1.path, "/_matrix/federation/v1/send/"))
          |> Enum.flat_map(&(&1.body["edus"] || []))
          |> Enum.find(fn edu ->
            edu["edu_type"] == "m.device_list_update" and
              edu["content"]["user_id"] == alice.user_id
          end)
          |> case do
            nil -> :error
            edu -> {:ok, edu}
          end
        end)

      assert req["content"]["device_id"] == alice.device_id
      assert req["content"]["deleted"] == false
      assert is_integer(req["content"]["stream_id"])
    end

    test "does not fan out a remote user's own device list back out to anyone" do
      alice = register("alice_dlfed_noloop_#{System.unique_integer([:positive])}")
      bob = remote_user_id("bob")

      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join_remote_member(room_id, bob)

      # The join itself legitimately queues a fan-out for *alice* (she's
      # local and now shares the room with bob's server) — let that drain
      # first so it isn't mistaken below for a leak of bob's own update.
      Process.sleep(1_500)
      FakeRemoteMatrixServer.clear_requests(@port)

      # Simulates what the inbound m.device_list_update handler itself does
      # on receipt — recording it locally must not cause this server to
      # turn around and re-announce it as if it were the origin.
      KeyStore.record_device_list_update(bob)

      # Give AxonFederation.DeviceListFanout's poller (500ms interval)
      # multiple chances to (incorrectly) act before asserting it didn't.
      Process.sleep(1_500)

      refute FakeRemoteMatrixServer.requests(@port)
             |> Enum.flat_map(&(&1.body["edus"] || []))
             |> Enum.any?(fn edu ->
               edu["edu_type"] == "m.device_list_update" and edu["content"]["user_id"] == bob
             end)
    end

    # Regression: AxonFederation.DeviceListFanout's scan cursor used to
    # live only in the GenServer's own memory, starting at 0 on every
    # init/1 — indistinguishable, at the Elixir level, from a genuine
    # process/container restart (not just an in-app crash). A restart
    # re-scanned the *entire* device_list_updates table from the
    # beginning and re-fanned every historical change any local user ever
    # had, all over again — landing as spurious duplicate
    # "m.device_list_update" EDUs for changes a remote peer already
    # correctly knew about (Complement:
    # TestDeviceListsUpdateOverFederation's interrupted_connectivity/
    # stopped_server subtests, which restart a homeserver container
    # mid-test — indistinguishable from a fresh boot here). The cursor is
    # now persisted (device_list_fanout_cursor) and reloaded on restart
    # instead of defaulting back to 0.
    test "a restart of the fanout process does not re-announce an already-fanned-out change" do
      alice = register("alice_dlfed_restart_#{System.unique_integer([:positive])}")
      bob = remote_user_id("bob")

      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join_remote_member(room_id, bob)

      KeyStore.record_device_list_update(alice.user_id)

      wait_until(System.monotonic_time(:millisecond) + 3_000, fn ->
        FakeRemoteMatrixServer.requests(@port)
        |> Enum.flat_map(&(&1.body["edus"] || []))
        |> Enum.find(fn edu ->
          edu["edu_type"] == "m.device_list_update" and
            edu["content"]["user_id"] == alice.user_id
        end)
        |> case do
          nil -> :error
          edu -> {:ok, edu}
        end
      end)

      FakeRemoteMatrixServer.clear_requests(@port)

      # Simulates a process/container restart — the supervisor (:one_for_one)
      # brings it straight back up, calling init/1 fresh.
      pid_before = Process.whereis(AxonFederation.DeviceListFanout)
      Process.exit(pid_before, :kill)

      wait_until(System.monotonic_time(:millisecond) + 3_000, fn ->
        case Process.whereis(AxonFederation.DeviceListFanout) do
          nil -> :error
          pid when pid != pid_before -> {:ok, pid}
          _ -> :error
        end
      end)

      # Give the restarted poller several ticks (500ms interval) to
      # (incorrectly) re-announce alice's already-fanned-out change.
      Process.sleep(1_500)

      refute FakeRemoteMatrixServer.requests(@port)
             |> Enum.flat_map(&(&1.body["edus"] || []))
             |> Enum.any?(fn edu ->
               edu["edu_type"] == "m.device_list_update" and
                 edu["content"]["user_id"] == alice.user_id
             end)
    end

    test "an inbound m.device_list_update EDU surfaces the remote sender in the local room-mate's device_lists.changed" do
      alice = register("alice_dlfed_in_#{System.unique_integer([:positive])}")
      bob = remote_user_id("bob")

      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      join_remote_member(room_id, bob)

      alice_since = sync_once(alice.token)["next_batch"]

      edu = %{
        "edu_type" => "m.device_list_update",
        "content" => %{
          "user_id" => bob,
          "device_id" => "BOBDEVICE",
          "device_display_name" => "Bob's New Phone",
          "stream_id" => 1,
          "prev_id" => [],
          "deleted" => false
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

      alice_next = sync_once(alice.token, alice_since)
      assert bob in alice_next["device_lists"]["changed"]
    end

    test "an inbound m.device_list_update EDU claiming a user_id the sending server doesn't own is dropped" do
      alice = register("alice_dlfed_forged_#{System.unique_integer([:positive])}")
      not_bobs_server = "@impostor:some-other-server.test"

      edu = %{
        "edu_type" => "m.device_list_update",
        "content" => %{
          "user_id" => not_bobs_server,
          "device_id" => "X",
          "stream_id" => 1,
          "prev_id" => [],
          "deleted" => false
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

      # The transaction as a whole still 200s (per-EDU processing is
      # best-effort, same as every other EDU type) -- what matters is that
      # the forged update was never recorded.
      assert conn.status == 200
      refute alice.user_id == not_bobs_server

      alice_since = sync_once(alice.token)["next_batch"]
      alice_next = sync_once(alice.token, alice_since)
      refute not_bobs_server in alice_next["device_lists"]["changed"]
    end
  end
end
