defmodule AxonWeb.KeyBackupConsistencyTest do
  @moduledoc """
  Regression tests for a key-backup consistency bug found during Phase 11
  hardening: `PUT /room_keys/keys` never validated the `version` query
  param against the user's actual current backup version. A client
  retrying against a stale or deleted version (e.g. after losing a race
  with another of its own devices rotating the backup) would silently
  insert rows under that version with no error — `count`/`etag` on
  `GET /room_keys/version` would never reflect the write, and the rows
  would sit orphaned under a version nothing reads back. Per spec this
  must 403 M_WRONG_ROOM_KEYS_VERSION instead.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  defp create_version(token) do
    conn =
      authed(token)
      |> jp("/_matrix/client/v3/room_keys/version", %{
        "algorithm" => "m.megolm_backup.v1.curve25519-aes-sha2",
        "auth_data" => %{}
      })

    assert conn.status == 200
    decode(conn)["version"]
  end

  defp put_keys(token, version, room_id, session_id, session_data \\ %{"k" => "v"}) do
    authed(token)
    |> jpu("/_matrix/client/v3/room_keys/keys?version=#{version}", %{
      "rooms" => %{
        room_id => %{"sessions" => %{session_id => %{"session_data" => session_data}}}
      }
    })
  end

  test "PUT with no version param is rejected" do
    alice = register("kb_noversion_#{System.unique_integer([:positive])}")
    create_version(alice.token)

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/room_keys/keys", %{
        "rooms" => %{"!r:localhost" => %{"sessions" => %{"s1" => %{"session_data" => %{}}}}}
      })

    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_MISSING_PARAM"
  end

  test "PUT against a stale (superseded) version is rejected with the current version" do
    alice = register("kb_stale_#{System.unique_integer([:positive])}")
    v1 = create_version(alice.token)
    v2 = create_version(alice.token)

    conn = put_keys(alice.token, v1, "!r:localhost", "s1")

    assert conn.status == 403
    body = decode(conn)
    assert body["errcode"] == "M_WRONG_ROOM_KEYS_VERSION"
    assert body["current_version"] == v2
  end

  test "PUT against a deleted version is rejected" do
    alice = register("kb_deleted_#{System.unique_integer([:positive])}")
    v1 = create_version(alice.token)

    conn = authed(alice.token) |> delete("/_matrix/client/v3/room_keys/version/#{v1}")
    assert conn.status == 200

    conn = put_keys(alice.token, v1, "!r:localhost", "s1")
    assert conn.status == 403
    assert decode(conn)["errcode"] == "M_WRONG_ROOM_KEYS_VERSION"
  end

  test "PUT against the current version succeeds and count/etag stay consistent across uploads" do
    alice = register("kb_current_#{System.unique_integer([:positive])}")
    version = create_version(alice.token)

    conn = put_keys(alice.token, version, "!r1:localhost", "s1")
    assert conn.status == 200
    assert decode(conn)["count"] == 1

    version_conn = authed(alice.token) |> get("/_matrix/client/v3/room_keys/version")
    assert decode(version_conn)["count"] == 1
    etag_after_first = decode(version_conn)["etag"]

    conn = put_keys(alice.token, version, "!r2:localhost", "s2")
    assert conn.status == 200

    version_conn2 = authed(alice.token) |> get("/_matrix/client/v3/room_keys/version")
    body2 = decode(version_conn2)
    assert body2["count"] == 2
    assert body2["etag"] != etag_after_first
  end

  test "a second device racing a version rotation gets a clear error, not a silent no-op" do
    alice = register("kb_race_#{System.unique_integer([:positive])}")
    device_a_version = create_version(alice.token)

    # Device A uploaded successfully under the original version...
    assert put_keys(alice.token, device_a_version, "!r:localhost", "s1").status == 200

    # ...then device B rotates to a fresh backup (e.g. after a local reset).
    device_b_version = create_version(alice.token)
    assert put_keys(alice.token, device_b_version, "!r:localhost", "s1").status == 200

    # Device A, still holding the old version, must be told plainly rather
    # than have its upload silently vanish.
    conn = put_keys(alice.token, device_a_version, "!r:localhost", "s2")
    assert conn.status == 403
    assert decode(conn)["current_version"] == device_b_version
  end
end
