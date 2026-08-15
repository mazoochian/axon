defmodule AxonWeb.KeyBackupReplaceRulesTest do
  @moduledoc """
  Two independent bugs found via Complement's `TestE2EKeyBackupReplaceRoomKeyRules`:

  1. The single-session `PUT /room_keys/keys/{roomId}/{sessionId}` form (a
     bare `KeyBackupData` body, no `rooms`/`sessions` wrapper) was silently
     a no-op — `do_put_backup_keys/4` only ever looked at `params["rooms"]`,
     so nothing was ever written and the response still claimed success.
  2. Per spec (11.12.3.3), a key only *replaces* what's already backed up
     if it's "better": preferred order is is_verified=true over false, then
     a lower first_message_index, then a lower forwarded_count. Axon
     unconditionally overwrote on every conflict regardless of this.
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

  defp put_session_key(token, version, room_id, session_id, key) do
    authed(token)
    |> jpu(
      "/_matrix/client/v3/room_keys/keys/#{room_id}/#{session_id}?version=#{version}",
      Map.put(key, "session_data", %{"a" => "b"})
    )
  end

  defp get_session_key(token, version, room_id, session_id) do
    authed(token)
    |> get("/_matrix/client/v3/room_keys/keys/#{room_id}/#{session_id}?version=#{version}")
  end

  test "the single-session PUT form actually stores the key" do
    alice = register("kbr_single_#{System.unique_integer([:positive])}")
    version = create_version(alice.token)

    put_conn =
      put_session_key(alice.token, version, "!foo:hs1", "a", %{
        "first_message_index" => 10,
        "forwarded_count" => 5,
        "is_verified" => false
      })

    assert put_conn.status == 200

    get_conn = get_session_key(alice.token, version, "!foo:hs1", "a")
    assert get_conn.status == 200
    body = decode(get_conn)
    assert body["first_message_index"] == 10
    assert body["forwarded_count"] == 5
    assert body["is_verified"] == false
  end

  test "a key with a higher first_message_index does not replace an existing one" do
    alice = register("kbr_fmi_#{System.unique_integer([:positive])}")
    version = create_version(alice.token)

    put_session_key(alice.token, version, "!foo:hs1", "a", %{
      "first_message_index" => 10,
      "forwarded_count" => 5,
      "is_verified" => false
    })

    put_session_key(alice.token, version, "!foo:hs1", "a", %{
      "first_message_index" => 11,
      "forwarded_count" => 5,
      "is_verified" => false
    })

    body = decode(get_session_key(alice.token, version, "!foo:hs1", "a"))
    assert body["first_message_index"] == 10
  end

  test "a key with a lower first_message_index does replace an existing one" do
    alice = register("kbr_fmi_lower_#{System.unique_integer([:positive])}")
    version = create_version(alice.token)

    put_session_key(alice.token, version, "!foo:hs1", "a", %{
      "first_message_index" => 10,
      "forwarded_count" => 5,
      "is_verified" => false
    })

    put_session_key(alice.token, version, "!foo:hs1", "a", %{
      "first_message_index" => 9,
      "forwarded_count" => 5,
      "is_verified" => false
    })

    body = decode(get_session_key(alice.token, version, "!foo:hs1", "a"))
    assert body["first_message_index"] == 9
  end

  test "is_verified=true is never replaced by is_verified=false, regardless of the other fields" do
    alice = register("kbr_verified_#{System.unique_integer([:positive])}")
    version = create_version(alice.token)

    put_session_key(alice.token, version, "!foo:hs1", "b", %{
      "first_message_index" => 10,
      "forwarded_count" => 5,
      "is_verified" => true
    })

    put_session_key(alice.token, version, "!foo:hs1", "b", %{
      "first_message_index" => 1,
      "forwarded_count" => 1,
      "is_verified" => false
    })

    body = decode(get_session_key(alice.token, version, "!foo:hs1", "b"))
    assert body["is_verified"] == true
    assert body["first_message_index"] == 10
  end

  test "when is_verified and first_message_index are equal, a lower forwarded_count replaces" do
    alice = register("kbr_fwd_#{System.unique_integer([:positive])}")
    version = create_version(alice.token)

    put_session_key(alice.token, version, "!foo:hs1", "c", %{
      "first_message_index" => 10,
      "forwarded_count" => 5,
      "is_verified" => false
    })

    put_session_key(alice.token, version, "!foo:hs1", "c", %{
      "first_message_index" => 10,
      "forwarded_count" => 4,
      "is_verified" => false
    })

    body = decode(get_session_key(alice.token, version, "!foo:hs1", "c"))
    assert body["forwarded_count"] == 4
  end
end
