defmodule AxonWeb.CryptoIdentityTest do
  @moduledoc """
  Integration test for the full Matrix E2EE crypto identity setup flow.

  Covers the sequence that FluffyChat's matrix_dart_sdk `initCryptoIdentity` /
  `Bootstrap.init` performs when a user enables encryption for the first time:

    1. Register users
    2. Upload device keys + OTKs
    3. Upload cross-signing keys (UIA: 401 challenge → m.login.dummy → 200)
    4. Write SSSS account data (m.secret_storage.default_key etc.)
    5. Create key backup version
    6. Write backup reference to account data
    7. Verify cross-signing keys appear in /keys/query response
    8. Verify backup is readable and user-scoped
    9. Upload and retrieve a session key backup
  """

  use AxonWeb.ConnCase, async: false

  @server "localhost"

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

    %{
      token: body["access_token"],
      device_id: body["device_id"],
      user_id: body["user_id"]
    }
  end

  defp authed(token) do
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end

  defp jp(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp jpu(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put(path, Jason.encode!(body))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # Signs `key_json` (a cross-signing key object) with `master_priv`, the way
  # a real client signs self_signing_key/user_signing_key with the master
  # key: canonical JSON with "signatures" dropped, Ed25519 over that.
  defp sign_with_master(key_json, user_id, master_key_id, master_priv) do
    signable = key_json |> Map.drop(["signatures"]) |> AxonCrypto.CanonicalJSON.encode_to_binary()
    sig = :crypto.sign(:eddsa, :none, signable, [master_priv, :ed25519])
    sig_b64 = Base.encode64(sig, padding: false)
    Map.put(key_json, "signatures", %{user_id => %{master_key_id => sig_b64}})
  end

  # -------------------------------------------------------------------------
  # Tests
  # -------------------------------------------------------------------------

  describe "crypto identity setup flow" do
    test "full initCryptoIdentity flow for two users" do
      # Step 1: Register both users
      alice = register("alice_crypto_#{System.unique_integer([:positive])}")
      bob = register("bob_crypto_#{System.unique_integer([:positive])}")

      # Step 2: Upload device keys + OTKs for each user
      for %{token: token, device_id: dev, user_id: uid} <- [alice, bob] do
        conn =
          authed(token)
          |> jp("/_matrix/client/v3/keys/upload", %{
            "device_keys" => %{
              "user_id" => uid,
              "device_id" => dev,
              "algorithms" => ["m.olm.v1.curve25519-aes-sha2", "m.megolm.v1.aes-sha2"],
              "keys" => %{
                "curve25519:#{dev}" => "curve_key_#{dev}",
                "ed25519:#{dev}" => "ed_key_#{dev}"
              },
              "signatures" => %{
                uid => %{"ed25519:#{dev}" => "self_sig_#{dev}"}
              }
            },
            "one_time_keys" => %{
              "curve25519:OTK1" => %{"key" => "otk1_for_#{dev}"},
              "curve25519:OTK2" => %{"key" => "otk2_for_#{dev}"}
            }
          })

        assert conn.status == 200
        body = decode(conn)
        assert body["one_time_key_counts"]["curve25519"] == 2
      end

      # Step 3: Cross-signing upload flow for Alice
      #   3a. First call without auth → expect 401 UIA challenge
      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/keys/device_signing/upload", %{
          "master_key" => %{
            "keys" => %{"ed25519:alice_master_pub" => "alice_master_key_value"},
            "usage" => ["master"],
            "user_id" => alice.user_id
          },
          "self_signing_key" => %{
            "keys" => %{"ed25519:alice_self_pub" => "alice_self_signing_key_value"},
            "usage" => ["self_signing"],
            "user_id" => alice.user_id
          },
          "user_signing_key" => %{
            "keys" => %{"ed25519:alice_user_pub" => "alice_user_signing_key_value"},
            "usage" => ["user_signing"],
            "user_id" => alice.user_id
          }
        })

      assert conn.status == 401
      uia = decode(conn)
      assert is_binary(uia["session"])
      flows = Enum.map(uia["flows"], fn f -> f["stages"] end)
      assert Enum.any?(flows, fn stages -> "m.login.dummy" in stages end)
      session = uia["session"]

      #   3b. Retry with m.login.dummy auth → expect 200 {}
      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/keys/device_signing/upload", %{
          "auth" => %{"type" => "m.login.dummy", "session" => session},
          "master_key" => %{
            "keys" => %{"ed25519:alice_master_pub" => "alice_master_key_value"},
            "usage" => ["master"],
            "user_id" => alice.user_id
          },
          "self_signing_key" => %{
            "keys" => %{"ed25519:alice_self_pub" => "alice_self_signing_key_value"},
            "usage" => ["self_signing"],
            "user_id" => alice.user_id
          },
          "user_signing_key" => %{
            "keys" => %{"ed25519:alice_user_pub" => "alice_user_signing_key_value"},
            "usage" => ["user_signing"],
            "user_id" => alice.user_id
          }
        })

      assert conn.status == 200
      assert decode(conn) == %{}

      # Step 3: Cross-signing upload for Bob (same flow)
      conn =
        authed(bob.token)
        |> jp("/_matrix/client/v3/keys/device_signing/upload", %{
          "master_key" => %{
            "keys" => %{"ed25519:bob_master_pub" => "bob_master_key_value"},
            "usage" => ["master"],
            "user_id" => bob.user_id
          },
          "self_signing_key" => %{
            "keys" => %{"ed25519:bob_self_pub" => "bob_self_signing_key_value"},
            "usage" => ["self_signing"],
            "user_id" => bob.user_id
          },
          "user_signing_key" => %{
            "keys" => %{"ed25519:bob_user_pub" => "bob_user_signing_key_value"},
            "usage" => ["user_signing"],
            "user_id" => bob.user_id
          }
        })

      assert conn.status == 401
      bob_session = decode(conn)["session"]

      conn =
        authed(bob.token)
        |> jp("/_matrix/client/v3/keys/device_signing/upload", %{
          "auth" => %{"type" => "m.login.dummy", "session" => bob_session},
          "master_key" => %{
            "keys" => %{"ed25519:bob_master_pub" => "bob_master_key_value"},
            "usage" => ["master"],
            "user_id" => bob.user_id
          },
          "self_signing_key" => %{
            "keys" => %{"ed25519:bob_self_pub" => "bob_self_signing_key_value"},
            "usage" => ["self_signing"],
            "user_id" => bob.user_id
          },
          "user_signing_key" => %{
            "keys" => %{"ed25519:bob_user_pub" => "bob_user_signing_key_value"},
            "usage" => ["user_signing"],
            "user_id" => bob.user_id
          }
        })

      assert conn.status == 200

      # Step 4: Store SSSS account data (key storage metadata)
      key_id = "axon_test_key_#{System.unique_integer([:positive])}"

      for %{token: token, user_id: uid} <- [alice, bob] do
        # Default key pointer
        conn =
          authed(token)
          |> jpu(
            "/_matrix/client/v3/user/#{uid}/account_data/m.secret_storage.default_key",
            %{"key" => key_id}
          )

        assert conn.status == 200

        # Key description
        conn =
          authed(token)
          |> jpu(
            "/_matrix/client/v3/user/#{uid}/account_data/m.secret_storage.key.#{key_id}",
            %{
              "algorithm" => "m.secret_storage.v1.aes-hmac-sha2",
              "name" => "Default Key"
            }
          )

        assert conn.status == 200

        # Master key SSSS encryption
        conn =
          authed(token)
          |> jpu(
            "/_matrix/client/v3/user/#{uid}/account_data/m.cross_signing.master",
            %{
              "encrypted" => %{
                key_id => %{"iv" => "testiv", "ciphertext" => "testcipher", "mac" => "testmac"}
              }
            }
          )

        assert conn.status == 200

        conn =
          authed(token)
          |> jpu(
            "/_matrix/client/v3/user/#{uid}/account_data/m.cross_signing.self_signing",
            %{
              "encrypted" => %{
                key_id => %{"iv" => "testiv2", "ciphertext" => "testcipher2", "mac" => "testmac2"}
              }
            }
          )

        assert conn.status == 200

        conn =
          authed(token)
          |> jpu(
            "/_matrix/client/v3/user/#{uid}/account_data/m.cross_signing.user_signing",
            %{
              "encrypted" => %{
                key_id => %{"iv" => "testiv3", "ciphertext" => "testcipher3", "mac" => "testmac3"}
              }
            }
          )

        assert conn.status == 200

        # Read back default key pointer to verify
        conn =
          authed(token)
          |> get("/_matrix/client/v3/user/#{uid}/account_data/m.secret_storage.default_key")

        assert conn.status == 200
        assert decode(conn)["key"] == key_id
      end

      # Step 5: Create key backup versions (each user gets their own)
      alice_backup_conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/room_keys/version", %{
          "algorithm" => "m.megolm_backup.v1.curve25519-aes-sha2",
          "auth_data" => %{
            "public_key" => "alice_backup_pub_key_abcdefghijklmnop",
            "signatures" => %{}
          }
        })

      assert alice_backup_conn.status == 200
      alice_version = decode(alice_backup_conn)["version"]
      assert is_binary(alice_version)

      bob_backup_conn =
        authed(bob.token)
        |> jp("/_matrix/client/v3/room_keys/version", %{
          "algorithm" => "m.megolm_backup.v1.curve25519-aes-sha2",
          "auth_data" => %{
            "public_key" => "bob_backup_pub_key_abcdefghijklmnopq",
            "signatures" => %{}
          }
        })

      assert bob_backup_conn.status == 200
      bob_version = decode(bob_backup_conn)["version"]
      assert is_binary(bob_version)

      # Step 5b: Verify versions are user-scoped — each user sees only their own
      conn = authed(alice.token) |> get("/_matrix/client/v3/room_keys/version")
      assert conn.status == 200
      alice_ver_data = decode(conn)
      assert alice_ver_data["version"] == alice_version
      assert alice_ver_data["auth_data"]["public_key"] == "alice_backup_pub_key_abcdefghijklmnop"

      conn = authed(bob.token) |> get("/_matrix/client/v3/room_keys/version")
      assert conn.status == 200
      bob_ver_data = decode(conn)
      assert bob_ver_data["version"] == bob_version
      assert bob_ver_data["auth_data"]["public_key"] == "bob_backup_pub_key_abcdefghijklmnopq"

      # Versions must be different
      refute alice_version == bob_version

      # Step 6: Store backup version reference in account data
      for {%{token: token, user_id: uid}, ver} <- [{alice, alice_version}, {bob, bob_version}] do
        conn =
          authed(token)
          |> jpu(
            "/_matrix/client/v3/user/#{uid}/account_data/m.megolm_backup.v1",
            %{"version" => ver, "algorithm" => "m.megolm_backup.v1.curve25519-aes-sha2"}
          )

        assert conn.status == 200
      end

      # Step 7: keys/query — both users' cross-signing keys should appear
      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/keys/query", %{
          "device_keys" => %{
            alice.user_id => [],
            bob.user_id => []
          }
        })

      assert conn.status == 200
      q = decode(conn)

      # Alice's device keys
      assert Map.has_key?(q["device_keys"][alice.user_id], alice.device_id)

      # Alice's cross-signing keys (querying for others returns master + self_signing,
      # user_signing only for self per spec)
      assert Map.has_key?(q["master_keys"], alice.user_id)
      assert Map.has_key?(q["master_keys"], bob.user_id)
      assert Map.has_key?(q["self_signing_keys"], alice.user_id)
      assert Map.has_key?(q["self_signing_keys"], bob.user_id)

      # user_signing only returned for self (alice is querying)
      assert Map.has_key?(q["user_signing_keys"], alice.user_id)

      # Verify content of Alice's master key
      alice_master = q["master_keys"][alice.user_id]
      assert alice_master["keys"]["ed25519:alice_master_pub"] == "alice_master_key_value"
      assert alice_master["usage"] == ["master"]

      # Step 8: Upload a session key to backup
      conn =
        authed(alice.token)
        |> jpu(
          "/_matrix/client/v3/room_keys/keys?version=#{alice_version}",
          %{
            "rooms" => %{
              "!test_room:#{@server}" => %{
                "sessions" => %{
                  "test_session_id_abc123" => %{
                    "first_message_index" => 0,
                    "forwarded_count" => 0,
                    "is_verified" => true,
                    "session_data" => %{
                      "ephemeral" => "ephem_key_abc",
                      "ciphertext" => "encrypted_session_abc",
                      "mac" => "mac_abc"
                    }
                  }
                }
              }
            }
          }
        )

      assert conn.status == 200

      # Step 9: Retrieve the session key from backup
      conn =
        authed(alice.token)
        |> get(
          "/_matrix/client/v3/room_keys/keys/#{URI.encode("!test_room:#{@server}")}/test_session_id_abc123?version=#{alice_version}"
        )

      assert conn.status == 200
      key_data = decode(conn)
      assert key_data["first_message_index"] == 0
      assert key_data["is_verified"] == true
      assert key_data["session_data"]["ciphertext"] == "encrypted_session_abc"

      # Bob cannot read Alice's backup keys (different user_id filter)
      conn =
        authed(bob.token)
        |> get(
          "/_matrix/client/v3/room_keys/keys/#{URI.encode("!test_room:#{@server}")}/test_session_id_abc123?version=#{alice_version}"
        )

      # Should be 404 since version belongs to alice, bob sees empty
      assert conn.status == 404
    end

    test "cross-signing upload rejects unknown auth type" do
      user = register("cs_auth_test_#{System.unique_integer([:positive])}")

      conn =
        authed(user.token)
        |> jp("/_matrix/client/v3/keys/device_signing/upload", %{
          "auth" => %{"type" => "m.login.sso", "session" => "fakesession"},
          "master_key" => %{
            "keys" => %{"ed25519:pub" => "val"},
            "usage" => ["master"],
            "user_id" => user.user_id
          }
        })

      # m.login.sso is not an accepted UIA type for this endpoint — must be
      # rejected with a fresh 401 challenge, not silently accepted.
      assert conn.status == 401
      assert decode(conn)["errcode"] == "M_FORBIDDEN"
    end

    test "MSC3967: first-time upload of master+self+user signing keys together skips UIA" do
      user = register("msc3967_first_#{System.unique_integer([:positive])}")

      # Brand-new account, no master key on file yet -- per MSC3967 this
      # entire first upload succeeds with no "auth" block at all, since
      # there's nothing yet to protect (the access token is proof enough).
      conn =
        authed(user.token)
        |> jp("/_matrix/client/v3/keys/device_signing/upload", %{
          "master_key" => %{
            "keys" => %{"ed25519:msc3967_first_master" => "master_pub"},
            "usage" => ["master"],
            "user_id" => user.user_id
          },
          "self_signing_key" => %{
            "keys" => %{"ed25519:msc3967_first_self" => "self_pub"},
            "usage" => ["self_signing"],
            "user_id" => user.user_id
          },
          "user_signing_key" => %{
            "keys" => %{"ed25519:msc3967_first_user" => "user_pub"},
            "usage" => ["user_signing"],
            "user_id" => user.user_id
          }
        })

      assert conn.status == 200

      query =
        authed(user.token)
        |> jp("/_matrix/client/v3/keys/query", %{"device_keys" => %{user.user_id => []}})

      body = decode(query)

      assert body["master_keys"][user.user_id]["keys"]["ed25519:msc3967_first_master"] ==
               "master_pub"

      assert body["self_signing_keys"][user.user_id]["keys"]["ed25519:msc3967_first_self"] ==
               "self_pub"

      assert body["user_signing_keys"][user.user_id]["keys"]["ed25519:msc3967_first_user"] ==
               "user_pub"
    end

    test "MSC3967: retrying the exact same upload is idempotent and skips UIA" do
      user = register("msc3967_retry_#{System.unique_integer([:positive])}")

      keys = %{
        "master_key" => %{
          "keys" => %{"ed25519:msc3967_retry_master" => "master_pub"},
          "usage" => ["master"],
          "user_id" => user.user_id
        },
        "self_signing_key" => %{
          "keys" => %{"ed25519:msc3967_retry_self" => "self_pub"},
          "usage" => ["self_signing"],
          "user_id" => user.user_id
        }
      }

      first = authed(user.token) |> jp("/_matrix/client/v3/keys/device_signing/upload", keys)
      assert first.status == 200

      # Simulates the original 200 OK getting lost in transit -- the client
      # retries with the identical body and no "auth". Must still succeed,
      # since nothing in the request is actually new.
      retry = authed(user.token) |> jp("/_matrix/client/v3/keys/device_signing/upload", keys)
      assert retry.status == 200
    end

    test "MSC3967: uploading a different master key without UIA is rejected" do
      user = register("msc3967_reset_#{System.unique_integer([:positive])}")

      original = %{
        "master_key" => %{
          "keys" => %{"ed25519:msc3967_reset_master1" => "master_pub_1"},
          "usage" => ["master"],
          "user_id" => user.user_id
        }
      }

      established =
        authed(user.token) |> jp("/_matrix/client/v3/keys/device_signing/upload", original)

      assert established.status == 200

      # A genuinely different master key (an identity reset) must never be
      # accepted without UIA, no matter how it's presented.
      replacement = %{
        "master_key" => %{
          "keys" => %{"ed25519:msc3967_reset_master2" => "master_pub_2"},
          "usage" => ["master"],
          "user_id" => user.user_id
        }
      }

      conn =
        authed(user.token) |> jp("/_matrix/client/v3/keys/device_signing/upload", replacement)

      assert conn.status == 401
    end

    test "MSC3967: adding a new self_signing_key to an established master key without UIA is rejected" do
      user = register("msc3967_newkey_#{System.unique_integer([:positive])}")

      master_key = %{
        "keys" => %{"ed25519:msc3967_newkey_master" => "master_pub"},
        "usage" => ["master"],
        "user_id" => user.user_id
      }

      established =
        authed(user.token)
        |> jp("/_matrix/client/v3/keys/device_signing/upload", %{"master_key" => master_key})

      assert established.status == 200

      # Same (unchanged) master key, but a self_signing_key that was never
      # uploaded before -- this is a *new* key, so UIA is still required.
      conn =
        authed(user.token)
        |> jp("/_matrix/client/v3/keys/device_signing/upload", %{
          "master_key" => master_key,
          "self_signing_key" => %{
            "keys" => %{"ed25519:msc3967_newkey_self" => "self_pub"},
            "usage" => ["self_signing"],
            "user_id" => user.user_id
          }
        })

      assert conn.status == 401
    end

    test "GET /room_keys/version returns 404 when user has no backup" do
      user = register("no_backup_#{System.unique_integer([:positive])}")

      conn = authed(user.token) |> get("/_matrix/client/v3/room_keys/version")
      assert conn.status == 404
      assert decode(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "key backup version delete" do
      user = register("backup_del_#{System.unique_integer([:positive])}")

      conn =
        authed(user.token)
        |> jp("/_matrix/client/v3/room_keys/version", %{
          "algorithm" => "m.megolm_backup.v1.curve25519-aes-sha2",
          "auth_data" => %{"public_key" => "deltest_pub"}
        })

      assert conn.status == 200
      version = decode(conn)["version"]

      conn = authed(user.token) |> delete("/_matrix/client/v3/room_keys/version/#{version}")
      assert conn.status == 200

      conn = authed(user.token) |> get("/_matrix/client/v3/room_keys/version/#{version}")
      assert conn.status == 404
    end
  end
end
