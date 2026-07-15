defmodule AxonWeb.E2EESyncTest do
  @moduledoc """
  Integration tests for Phase 3 E2EE sync additions:
    - to_device message delivery via /sync
    - device_one_time_keys_count in sync response
    - device_unused_fallback_key_types in sync response
    - device_lists.changed when a room-sharing user uploads new keys
    - /keys/changes endpoint
  """

  use AxonWeb.ConnCase, async: false

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

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
    %{token: body["access_token"], device_id: body["device_id"], user_id: body["user_id"]}
  end

  defp authed(token) do
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end

  defp jp(conn, path, body) do
    conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))
  end

  defp jpu(conn, path, body) do
    conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp sync(token, since \\ nil) do
    path =
      if since,
        do: "/_matrix/client/v3/sync?since=#{since}&timeout=0",
        else: "/_matrix/client/v3/sync?timeout=0"

    conn = authed(token) |> get(path)
    assert conn.status == 200
    decode(conn)
  end

  defp upload_device_keys(token, user_id, device_id) do
    conn =
      authed(token)
      |> jp("/_matrix/client/v3/keys/upload", %{
        "device_keys" => %{
          "user_id" => user_id,
          "device_id" => device_id,
          "algorithms" => ["m.olm.v1.curve25519-aes-sha2", "m.megolm.v1.aes-sha2"],
          "keys" => %{
            "curve25519:#{device_id}" => "curve_#{device_id}",
            "ed25519:#{device_id}" => "ed_#{device_id}"
          },
          "signatures" => %{user_id => %{"ed25519:#{device_id}" => "sig_#{device_id}"}}
        },
        "one_time_keys" => %{
          "curve25519:OTK1" => %{"key" => "otk1_#{device_id}"},
          "curve25519:OTK2" => %{"key" => "otk2_#{device_id}"}
        }
      })

    assert conn.status == 200
    conn
  end

  defp create_dm_room(token, invitee_user_id) do
    conn =
      authed(token)
      |> jp("/_matrix/client/v3/createRoom", %{
        "is_direct" => true,
        "invite" => [invitee_user_id],
        "preset" => "private_chat"
      })

    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp join_room(token, room_id) do
    conn = authed(token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    assert conn.status == 200
  end

  # -------------------------------------------------------------------------
  # Tests
  # -------------------------------------------------------------------------

  describe "to_device message delivery" do
    test "to_device messages appear in sync and are cleared afterwards" do
      alice = register("alice_tdm_#{System.unique_integer([:positive])}")
      bob = register("bob_tdm_#{System.unique_integer([:positive])}")

      # Alice sends a to-device message to Bob
      conn =
        authed(alice.token)
        |> jpu(
          "/_matrix/client/v3/sendToDevice/m.room.encrypted/txn#{System.unique_integer()}",
          %{
            "messages" => %{
              bob.user_id => %{
                bob.device_id => %{
                  "algorithm" => "m.olm.v1.curve25519-aes-sha2",
                  "ciphertext" => "encrypted_payload_for_bob"
                }
              }
            }
          }
        )

      assert conn.status == 200

      # Bob syncs — should receive the to-device message
      s = sync(bob.token)
      events = s["to_device"]["events"]
      assert is_list(events)
      assert length(events) == 1
      [event] = events
      assert event["type"] == "m.room.encrypted"
      assert event["sender"] == alice.user_id
      assert event["content"]["ciphertext"] == "encrypted_payload_for_bob"

      # Second sync — message should be gone (deleted on delivery)
      next_batch = s["next_batch"]
      s2 = sync(bob.token, next_batch)
      assert s2["to_device"]["events"] == []
    end

    test "to_device messages are device-scoped (other devices don't see them)" do
      alice = register("alice_scope_#{System.unique_integer([:positive])}")
      bob1 = register("bob_scope1_#{System.unique_integer([:positive])}")

      # Bob has only one device per registration — the second device scenario
      # would require a second login, but we're just verifying single-device scoping here.

      # Bob has only one device in this test — just confirm message targets that device
      conn =
        authed(alice.token)
        |> jpu(
          "/_matrix/client/v3/sendToDevice/m.key.verification.request/txn#{System.unique_integer()}",
          %{
            "messages" => %{
              bob1.user_id => %{
                bob1.device_id => %{"from_device" => alice.device_id, "methods" => ["m.sas.v1"]}
              }
            }
          }
        )

      assert conn.status == 200

      # Alice's sync should have empty to_device
      s = sync(alice.token)
      assert s["to_device"]["events"] == []

      # Bob1's sync gets the verification request
      s = sync(bob1.token)
      events = s["to_device"]["events"]
      assert length(events) == 1
      assert hd(events)["type"] == "m.key.verification.request"
    end
  end

  describe "OTK counts in sync" do
    test "device_one_time_keys_count reflects current unclaimed OTK count" do
      user = register("otk_count_#{System.unique_integer([:positive])}")

      # Initial sync — no OTKs uploaded yet
      s = sync(user.token)
      counts = s["device_one_time_keys_count"]
      assert counts == %{} or Map.get(counts, "curve25519", 0) == 0

      # Upload 3 OTKs
      authed(user.token)
      |> jp("/_matrix/client/v3/keys/upload", %{
        "one_time_keys" => %{
          "curve25519:A" => %{"key" => "kA"},
          "curve25519:B" => %{"key" => "kB"},
          "curve25519:C" => %{"key" => "kC"}
        }
      })
      |> then(fn conn -> assert conn.status == 200 end)

      # Sync should now report 3 unclaimed curve25519 OTKs
      s2 = sync(user.token, s["next_batch"])
      assert s2["device_one_time_keys_count"]["curve25519"] == 3
    end

    test "device_unused_fallback_key_types lists algorithms with unused fallback keys" do
      user = register("fb_types_#{System.unique_integer([:positive])}")

      s = sync(user.token)
      assert s["device_unused_fallback_key_types"] == []

      authed(user.token)
      |> jp("/_matrix/client/v3/keys/upload", %{
        "fallback_keys" => %{
          "curve25519" => %{"key" => "fb_key_val", "fallback" => true}
        }
      })
      |> then(fn conn -> assert conn.status == 200 end)

      s2 = sync(user.token, s["next_batch"])
      assert "curve25519" in s2["device_unused_fallback_key_types"]
    end
  end

  describe "device_lists.changed" do
    test "reports user as changed when they upload new keys in a shared room" do
      alice = register("alice_dl_#{System.unique_integer([:positive])}")
      bob = register("bob_dl_#{System.unique_integer([:positive])}")

      # Create a room and have both users join
      room_id = create_dm_room(alice.token, bob.user_id)
      join_room(bob.token, room_id)

      # Alice syncs to establish a baseline
      s = sync(alice.token)
      next_batch = s["next_batch"]

      # Bob uploads device keys
      upload_device_keys(bob.token, bob.user_id, bob.device_id)

      # Alice incremental-syncs — Bob should appear in device_lists.changed
      s2 = sync(alice.token, next_batch)
      assert bob.user_id in s2["device_lists"]["changed"]
    end

    test "does not report users in non-shared rooms" do
      alice = register("alice_noshare_#{System.unique_integer([:positive])}")
      bob = register("bob_noshare_#{System.unique_integer([:positive])}")

      # Alice and Bob do NOT share a room

      s = sync(alice.token)
      next_batch = s["next_batch"]

      upload_device_keys(bob.token, bob.user_id, bob.device_id)

      s2 = sync(alice.token, next_batch)
      refute bob.user_id in s2["device_lists"]["changed"]
    end

    test "initial sync returns empty device_lists" do
      alice = register("alice_init_dl_#{System.unique_integer([:positive])}")
      s = sync(alice.token)
      assert s["device_lists"]["changed"] == []
      assert s["device_lists"]["left"] == []
    end
  end

  describe "GET /keys/changes" do
    test "returns changed users between two sync tokens" do
      alice = register("alice_kc_#{System.unique_integer([:positive])}")
      bob = register("bob_kc_#{System.unique_integer([:positive])}")

      # Share a room
      room_id = create_dm_room(alice.token, bob.user_id)
      join_room(bob.token, room_id)

      s_before = sync(alice.token)
      from_token = s_before["next_batch"]

      # Bob uploads keys
      upload_device_keys(bob.token, bob.user_id, bob.device_id)

      s_after = sync(alice.token, from_token)
      to_token = s_after["next_batch"]

      # Call /keys/changes
      conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/keys/changes?from=#{from_token}&to=#{to_token}")

      assert conn.status == 200
      body = decode(conn)
      assert bob.user_id in body["changed"]
      assert is_list(body["left"])
    end

    test "returns empty when no keys changed" do
      alice = register("alice_kc_empty_#{System.unique_integer([:positive])}")
      s = sync(alice.token)
      from_token = s["next_batch"]

      # Nothing changed
      s2 = sync(alice.token, from_token)
      to_token = s2["next_batch"]

      conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/keys/changes?from=#{from_token}&to=#{to_token}")

      assert conn.status == 200
      body = decode(conn)
      assert body["changed"] == []
      assert body["left"] == []
    end
  end
end
