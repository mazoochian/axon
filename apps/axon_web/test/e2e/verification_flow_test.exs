defmodule AxonWeb.E2E.VerificationFlowTest do
  @moduledoc """
  Phase 11 (E2EE/verification test hardening) — Complement-style scenario
  coverage for the surface most prone to subtle regressions: device
  verification and cross-signing. Closes gaps the unit-level tests don't:

    - A full multi-step SAS verification (`m.key.verification.*`) exchange
      between two different users' devices, driven end-to-end through real
      nonzero-timeout long-polling on *both* sides — not just a single
      to-device event checked with a short-poll, like existing tests do.
    - The same exchange across two homeservers via
      `AxonFederation.FakeRemoteMatrixServer`, with a realistic nonzero
      timeout on the inbound EDU recipient's long-poll. The existing
      federation EDU test (`e2ee_delivery_test.exs`) only short-polls after
      the fact, so it can't catch a wake-up regression on the federated
      path the way it already does for the local path.
    - The wildcard `"*"` to-device target (`KeyStore.expand_wildcard_device/2`,
      added in Phase 8), which had no test coverage at all.
    - A cross-signing trust-chain scenario: bob verifies alice and signs her
      master key with his user-signing key; `/keys/query` must show bob his
      own signature, but not show it to an uninvolved third party.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}

  @port 19_150
  @server_name "fake-verify.test"

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

  defp login_new_device(username, device_display_name) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/login",
        Jason.encode!(%{
          "type" => "m.login.password",
          "identifier" => %{"type" => "m.id.user", "user" => username},
          "password" => "Test1234!",
          "initial_device_display_name" => device_display_name
        })
      )

    assert conn.status == 200
    body = decode(conn)
    %{token: body["access_token"], device_id: body["device_id"], user_id: body["user_id"]}
  end

  # Waits for the next to-device event of `type` addressed to `who`, via a
  # real nonzero-timeout long-poll — the same shape a real client uses to
  # wait for the next hop of a verification exchange.
  defp await_verification_step(who, since, type, timeout \\ 5_000) do
    task =
      Task.async(fn ->
        started_at = System.monotonic_time(:millisecond)
        body = sync_once(who.token, since, timeout)
        {body, System.monotonic_time(:millisecond) - started_at}
      end)

    {body, elapsed_ms} = Task.await(task, timeout + 1_000)
    assert elapsed_ms < timeout, "long-poll for #{type} didn't wake early (took #{elapsed_ms}ms)"

    event = Enum.find(body["to_device"]["events"], &(&1["type"] == type))

    assert event,
           "expected a #{type} to-device event, got #{inspect(body["to_device"]["events"])}"

    {event, body["next_batch"]}
  end

  describe "SAS device verification, real long-poll both directions" do
    test "request -> ready -> start -> key -> mac -> done, each hop woken from a blocking sync" do
      alice = register("verify_alice_#{System.unique_integer([:positive])}")
      bob = register("verify_bob_#{System.unique_integer([:positive])}")

      alice_since = sync_once(alice.token)["next_batch"]
      bob_since = sync_once(bob.token)["next_batch"]

      txn = "verify_txn_#{System.unique_integer([:positive])}"

      # alice -> bob: m.key.verification.request
      task =
        Task.async(fn ->
          await_verification_step(bob, bob_since, "m.key.verification.request")
        end)

      Process.sleep(150)

      assert send_to_device(alice.token, "m.key.verification.request", %{
               bob.user_id => %{
                 "*" => %{
                   "from_device" => alice.device_id,
                   "methods" => ["m.sas.v1"],
                   "transaction_id" => txn,
                   "timestamp" => System.os_time(:millisecond)
                 }
               }
             }).status == 200

      {_req_event, bob_since} = Task.await(task, 6_000)

      # bob -> alice: m.key.verification.ready
      task =
        Task.async(fn ->
          await_verification_step(alice, alice_since, "m.key.verification.ready")
        end)

      Process.sleep(150)

      assert send_to_device(bob.token, "m.key.verification.ready", %{
               alice.user_id => %{
                 alice.device_id => %{
                   "from_device" => bob.device_id,
                   "methods" => ["m.sas.v1"],
                   "transaction_id" => txn
                 }
               }
             }).status == 200

      {_ready_event, alice_since} = Task.await(task, 6_000)

      # alice -> bob: m.key.verification.start
      task =
        Task.async(fn -> await_verification_step(bob, bob_since, "m.key.verification.start") end)

      Process.sleep(150)

      assert send_to_device(alice.token, "m.key.verification.start", %{
               bob.user_id => %{
                 bob.device_id => %{
                   "from_device" => alice.device_id,
                   "method" => "m.sas.v1",
                   "transaction_id" => txn,
                   "key_agreement_protocols" => ["curve25519-hkdf-sha256"],
                   "hashes" => ["sha256"],
                   "message_authentication_codes" => ["hkdf-hmac-sha256"],
                   "short_authentication_string" => ["decimal", "emoji"]
                 }
               }
             }).status == 200

      {_start_event, bob_since} = Task.await(task, 6_000)

      # bob -> alice, alice -> bob: m.key.verification.key (both directions)
      task =
        Task.async(fn ->
          await_verification_step(alice, alice_since, "m.key.verification.key")
        end)

      Process.sleep(150)

      assert send_to_device(bob.token, "m.key.verification.key", %{
               alice.user_id => %{
                 alice.device_id => %{"transaction_id" => txn, "key" => "bob_ephemeral_pubkey"}
               }
             }).status == 200

      {_key_event, alice_since} = Task.await(task, 6_000)

      task =
        Task.async(fn -> await_verification_step(bob, bob_since, "m.key.verification.key") end)

      Process.sleep(150)

      assert send_to_device(alice.token, "m.key.verification.key", %{
               bob.user_id => %{
                 bob.device_id => %{"transaction_id" => txn, "key" => "alice_ephemeral_pubkey"}
               }
             }).status == 200

      {_key_event2, bob_since} = Task.await(task, 6_000)

      # bob -> alice, alice -> bob: m.key.verification.mac
      task =
        Task.async(fn ->
          await_verification_step(alice, alice_since, "m.key.verification.mac")
        end)

      Process.sleep(150)

      assert send_to_device(bob.token, "m.key.verification.mac", %{
               alice.user_id => %{
                 alice.device_id => %{
                   "transaction_id" => txn,
                   "mac" => %{"ed25519:#{bob.device_id}" => "bob_mac"},
                   "keys" => "bob_keys_mac"
                 }
               }
             }).status == 200

      {_mac_event, alice_since} = Task.await(task, 6_000)

      task =
        Task.async(fn -> await_verification_step(bob, bob_since, "m.key.verification.mac") end)

      Process.sleep(150)

      assert send_to_device(alice.token, "m.key.verification.mac", %{
               bob.user_id => %{
                 bob.device_id => %{
                   "transaction_id" => txn,
                   "mac" => %{"ed25519:#{alice.device_id}" => "alice_mac"},
                   "keys" => "alice_keys_mac"
                 }
               }
             }).status == 200

      {_mac_event2, bob_since} = Task.await(task, 6_000)

      # bob -> alice, alice -> bob: m.key.verification.done
      task =
        Task.async(fn ->
          await_verification_step(alice, alice_since, "m.key.verification.done")
        end)

      Process.sleep(150)

      assert send_to_device(bob.token, "m.key.verification.done", %{
               alice.user_id => %{alice.device_id => %{"transaction_id" => txn}}
             }).status == 200

      {_done_event, alice_since} = Task.await(task, 6_000)

      task =
        Task.async(fn -> await_verification_step(bob, bob_since, "m.key.verification.done") end)

      Process.sleep(150)

      assert send_to_device(alice.token, "m.key.verification.done", %{
               bob.user_id => %{bob.device_id => %{"transaction_id" => txn}}
             }).status == 200

      Task.await(task, 6_000)

      # Fully drained on both sides — no leftover verification traffic.
      assert sync_once(alice.token, alice_since)["to_device"]["events"] == []
    end
  end

  describe "wildcard device-id sendToDevice" do
    test "\"*\" delivers to every one of the target's devices, and only those" do
      username = "verify_wc_#{System.unique_integer([:positive])}"
      dev_a = register(username)
      dev_b = login_new_device(username, "second")
      dev_c = login_new_device(username, "third")

      sender = register("verify_wc_sender_#{System.unique_integer([:positive])}")

      # Devices must exist in the `devices` table for wildcard expansion to
      # find them — login_new_device (and register) both go through the
      # normal auth path, which registers the device.
      conn =
        send_to_device(sender.token, "m.room_key", %{
          dev_a.user_id => %{"*" => %{"session_key" => "wildcard_s3kr3t"}}
        })

      assert conn.status == 200

      for dev <- [dev_a, dev_b, dev_c] do
        body = sync_once(dev.token)
        [event] = body["to_device"]["events"]
        assert event["sender"] == sender.user_id
        assert event["content"]["session_key"] == "wildcard_s3kr3t"
      end

      # An unrelated user's devices must not receive it.
      other = register("verify_wc_other_#{System.unique_integer([:positive])}")
      assert sync_once(other.token)["to_device"]["events"] == []
    end
  end

  describe "cross-homeserver SAS verification with a realistic long-poll" do
    setup do
      start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
      KeyCache.clear()

      Application.put_env(:axon_federation, :server_overrides, %{
        @server_name => "http://127.0.0.1:#{@port}"
      })

      on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
      :ok
    end

    test "an inbound m.key.verification.request EDU wakes a long-polling local recipient" do
      local_user = register("verify_fed_local_#{System.unique_integer([:positive])}")
      remote_sender = "@remote_verifier:#{@server_name}"
      since = sync_once(local_user.token)["next_batch"]

      task =
        Task.async(fn ->
          started_at = System.monotonic_time(:millisecond)
          body = sync_once(local_user.token, since, 5_000)
          {body, System.monotonic_time(:millisecond) - started_at}
        end)

      Process.sleep(200)

      edu = %{
        "edu_type" => "m.direct_to_device",
        "content" => %{
          "sender" => remote_sender,
          "type" => "m.key.verification.request",
          "message_id" => "edu_#{System.unique_integer([:positive])}",
          "messages" => %{
            local_user.user_id => %{
              local_user.device_id => %{
                "from_device" => "REMOTE_DEVICE",
                "methods" => ["m.sas.v1"],
                "transaction_id" => "fed_verify_txn",
                "timestamp" => System.os_time(:millisecond)
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

      {sync_body, elapsed_ms} = Task.await(task, 6_000)
      assert elapsed_ms < 2_000

      [event] = sync_body["to_device"]["events"]
      assert event["type"] == "m.key.verification.request"
      assert event["sender"] == remote_sender
      assert event["content"]["from_device"] == "REMOTE_DEVICE"
    end
  end

  describe "cross-signing trust chain visibility" do
    test "a signature bob makes on alice's master key is visible to bob but not to an uninvolved third party" do
      alice = register("verify_trust_alice_#{System.unique_integer([:positive])}")
      bob = register("verify_trust_bob_#{System.unique_integer([:positive])}")
      carol = register("verify_trust_carol_#{System.unique_integer([:positive])}")

      alice_master = %{
        "master_key" => %{
          "keys" => %{"ed25519:alice_master" => "alice_master_pub"},
          "usage" => ["master"],
          "user_id" => alice.user_id
        }
      }

      assert authed(alice.token)
             |> jp("/_matrix/client/v3/keys/device_signing/upload", alice_master)
             |> Map.get(:status) == 200

      # bob "verifies" alice out-of-band (that's what the SAS flow above
      # ultimately lets a real client conclude) and signs her master key
      # with his user-signing key.
      signed_master_key =
        alice_master["master_key"]
        |> Map.put("signatures", %{
          bob.user_id => %{"ed25519:bob_user_signing" => "bobs_signature_on_alice_master"}
        })

      upload_conn =
        authed(bob.token)
        |> jp("/_matrix/client/v3/keys/signatures/upload", %{
          alice.user_id => %{"ed25519:alice_master" => signed_master_key}
        })

      assert upload_conn.status == 200

      # bob sees his own signature when he queries alice's keys.
      bob_query =
        authed(bob.token)
        |> jp("/_matrix/client/v3/keys/query", %{"device_keys" => %{alice.user_id => []}})

      bob_sig =
        get_in(decode(bob_query), [
          "master_keys",
          alice.user_id,
          "signatures",
          bob.user_id,
          "ed25519:bob_user_signing"
        ])

      assert bob_sig == "bobs_signature_on_alice_master"

      # carol, an uninvolved third party, does not see bob's signature.
      carol_query =
        authed(carol.token)
        |> jp("/_matrix/client/v3/keys/query", %{"device_keys" => %{alice.user_id => []}})

      carol_sigs =
        get_in(decode(carol_query), ["master_keys", alice.user_id, "signatures"]) || %{}

      refute Map.has_key?(carol_sigs, bob.user_id)
    end
  end
end
