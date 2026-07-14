defmodule AxonWeb.E2E.E2eeMultiDeviceTest do
  @moduledoc """
  End-to-end multi-device E2EE flow chaining pieces that are each
  unit-tested individually (key upload, cross-signing upload, to-device,
  key changes, sync) but never exercised together as a real client would:
  one user with two logged-in devices, a peer who queries both devices'
  keys, a to-device message routed to exactly one of the two devices and
  drained (not redelivered) on sync, and a device-list change surfaced to
  the peer via /keys/changes after cross-signing upload.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

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

  defp upload_device_keys(%{token: token, user_id: uid, device_id: dev}) do
    conn =
      authed(token)
      |> jp("/_matrix/client/v3/keys/upload", %{
        "device_keys" => %{
          "user_id" => uid,
          "device_id" => dev,
          "algorithms" => ["m.olm.v1.curve25519-aes-sha2", "m.megolm.v1.aes-sha2"],
          "keys" => %{
            "curve25519:#{dev}" => "curve_#{dev}",
            "ed25519:#{dev}" => "ed_#{dev}"
          },
          "signatures" => %{uid => %{"ed25519:#{dev}" => "selfsig_#{dev}"}}
        }
      })

    assert conn.status == 200
  end

  defp sync_once(token, since \\ nil) do
    path =
      if since,
        do: "/_matrix/client/v3/sync?since=#{since}",
        else: "/_matrix/client/v3/sync"

    conn = authed(token) |> get(path)
    assert conn.status == 200
    decode(conn)
  end

  test "two devices for one user, cross-device key query, targeted to-device delivery, and device-list changes" do
    username = "alice_#{System.unique_integer([:positive])}"
    alice_1 = register(username)
    alice_2 = login_new_device(username, "Alice's Second Device")
    assert alice_1.device_id != alice_2.device_id

    upload_device_keys(alice_1)
    upload_device_keys(alice_2)

    bob = register("bob_#{System.unique_integer([:positive])}")

    # A shared room is required for bob to see alice's device-list changes
    # via /keys/changes (axon scopes it to users who share a room).
    room_id = create_room(bob.token, %{"preset" => "public_chat"})

    assert authed(alice_1.token)
           |> jp("/_matrix/client/v3/join/#{room_id}", %{})
           |> Map.get(:status) == 200

    # --- bob queries alice's keys and sees BOTH devices ---
    query_conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/keys/query", %{"device_keys" => %{alice_1.user_id => []}})

    assert query_conn.status == 200
    alice_devices = decode(query_conn)["device_keys"][alice_1.user_id]
    assert Map.has_key?(alice_devices, alice_1.device_id)
    assert Map.has_key?(alice_devices, alice_2.device_id)

    # --- alice's first device sends a to-device message targeted ONLY at her second device ---
    send_conn =
      authed(alice_1.token)
      |> jpu(
        "/_matrix/client/v3/sendToDevice/m.room_key/txn_#{System.unique_integer([:positive])}",
        %{
          "messages" => %{
            alice_1.user_id => %{
              alice_2.device_id => %{
                "algorithm" => "m.megolm.v1.aes-sha2",
                "session_key" => "s3kr3t"
              }
            }
          }
        }
      )

    assert send_conn.status == 200

    # --- device 2 receives it on sync ---
    body2 = sync_once(alice_2.token)
    [to_device_event] = body2["to_device"]["events"]
    assert to_device_event["type"] == "m.room_key"
    assert to_device_event["sender"] == alice_1.user_id
    assert to_device_event["content"]["session_key"] == "s3kr3t"
    next_batch_2 = body2["next_batch"]

    # --- device 1 never receives it (it wasn't the target) ---
    body1 = sync_once(alice_1.token)
    assert body1["to_device"]["events"] == []

    # --- to-device messages are drained: a second sync for device 2 doesn't redeliver it ---
    body2_again = sync_once(alice_2.token, next_batch_2)
    assert body2_again["to_device"]["events"] == []

    # --- bob does an initial sync to establish a device-list baseline ---
    bob_initial = sync_once(bob.token)
    bob_since = bob_initial["next_batch"]

    # --- alice uploads cross-signing keys for the first time: MSC3967 exempts
    # first-time setup from UIA (nothing on file yet to protect), so this
    # succeeds directly with no auth round trip ---
    cross_sign_payload = %{
      "master_key" => %{
        "keys" => %{"ed25519:alice_master" => "alice_master_pub"},
        "usage" => ["master"],
        "user_id" => alice_1.user_id
      }
    }

    ok_conn =
      authed(alice_1.token)
      |> jp("/_matrix/client/v3/keys/device_signing/upload", cross_sign_payload)

    assert ok_conn.status == 200

    # --- but ROTATING to a different, unrelated master key (not signed by
    # the one now on file) still requires UIA ---
    rotated_payload = %{
      "master_key" => %{
        "keys" => %{"ed25519:alice_master_2" => "alice_master_pub_2"},
        "usage" => ["master"],
        "user_id" => alice_1.user_id
      }
    }

    uia_conn =
      authed(alice_1.token)
      |> jp("/_matrix/client/v3/keys/device_signing/upload", rotated_payload)

    assert uia_conn.status == 401
    session = decode(uia_conn)["session"]

    rotated_ok_conn =
      authed(alice_1.token)
      |> jp(
        "/_matrix/client/v3/keys/device_signing/upload",
        Map.put(rotated_payload, "auth", %{"type" => "m.login.dummy", "session" => session})
      )

    assert rotated_ok_conn.status == 200

    # --- bob's incremental sync (or /keys/changes) now reports alice as changed ---
    changes_conn =
      authed(bob.token)
      |> get("/_matrix/client/v3/keys/changes?from=#{bob_since}&to=#{bob_since}")

    assert changes_conn.status == 200

    bob_incremental = sync_once(bob.token, bob_since)
    assert alice_1.user_id in bob_incremental["device_lists"]["changed"]
  end
end
