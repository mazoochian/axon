defmodule AxonWeb.DeviceControllerTest do
  @moduledoc """
  Tests full device CRUD, including the normal password-based UIA path
  (the only prior coverage was the OIDC-bypass case in oidc_test.exs).
  """

  use AxonWeb.ConnCase, async: false

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
    %{token: body["access_token"], user_id: body["user_id"], device_id: body["device_id"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp jp(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp jpu(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "index lists all of the user's devices" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/devices")
    assert conn.status == 200
    assert Enum.any?(decode(conn)["devices"], &(&1["device_id"] == alice.device_id))
  end

  test "show returns a single device" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/devices/#{alice.device_id}")
    assert conn.status == 200
    assert decode(conn)["device_id"] == alice.device_id
  end

  test "an authenticated request updates last_seen_ts/last_seen_ip, not left null" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    conn = authed(alice.token) |> get("/_matrix/client/v3/devices/#{alice.device_id}")
    assert conn.status == 200
    body = decode(conn)

    assert is_integer(body["last_seen_ts"])
    assert body["last_seen_ts"] > 0
    assert is_binary(body["last_seen_ip"])
  end

  test "show for an unknown device_id 404s" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/devices/NONEXISTENT")
    assert conn.status == 404
  end

  test "update sets the display_name" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/devices/#{alice.device_id}", %{"display_name" => "My Phone"})

    assert conn.status == 200

    get_conn = authed(alice.token) |> get("/_matrix/client/v3/devices/#{alice.device_id}")
    assert decode(get_conn)["display_name"] == "My Phone"
  end

  test "delete requires UIA — a 401 challenge without auth" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> delete("/_matrix/client/v3/devices/#{alice.device_id}")
    assert conn.status == 401
    assert is_binary(decode(conn)["session"])
  end

  defp jd(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> delete(path, Jason.encode!(body))

  test "delete succeeds with correct password UIA" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    login_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/login",
        Jason.encode!(%{
          "type" => "m.login.password",
          "identifier" => %{"user" => alice.user_id},
          "password" => "Test1234!"
        })
      )

    other_device_id = decode(login_conn)["device_id"]

    auth = %{
      "type" => "m.login.password",
      "identifier" => %{"user" => alice.user_id},
      "password" => "Test1234!"
    }

    del_conn =
      authed(alice.token)
      |> jd("/_matrix/client/v3/devices/#{other_device_id}", %{"auth" => auth})

    assert del_conn.status == 200

    show_conn = authed(alice.token) |> get("/_matrix/client/v3/devices/#{other_device_id}")
    assert show_conn.status == 404
  end

  test "delete with wrong password UIA is rejected" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    auth = %{
      "type" => "m.login.password",
      "identifier" => %{"user" => alice.user_id},
      "password" => "WrongPassword!"
    }

    conn =
      authed(alice.token)
      |> jd("/_matrix/client/v3/devices/#{alice.device_id}", %{"auth" => auth})

    assert conn.status == 401
  end

  test "delete_devices (bulk) removes multiple devices with m.login.dummy" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    login_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/login",
        Jason.encode!(%{
          "type" => "m.login.password",
          "identifier" => %{"user" => alice.user_id},
          "password" => "Test1234!"
        })
      )

    device2 = decode(login_conn)["device_id"]

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/delete_devices", %{
        "devices" => [device2],
        "auth" => %{"type" => "m.login.dummy"}
      })

    assert conn.status == 200

    show_conn = authed(alice.token) |> get("/_matrix/client/v3/devices/#{device2}")
    assert show_conn.status == 404
  end

  # ---------------------------------------------------------------------------
  # Regression coverage: deleting/logging out of a device must also purge its
  # E2EE key material (device_keys/one_time_keys/fallback_keys), not just the
  # `devices` row -- otherwise /keys/query keeps serving keys for a session
  # that no longer exists, forever.
  # ---------------------------------------------------------------------------

  alias AxonCore.Repo
  import Ecto.Query, only: [from: 2]

  defp upload_device_keys(token, user_id, device_id) do
    conn =
      authed(token)
      |> jp("/_matrix/client/v3/keys/upload", %{
        "device_keys" => %{
          "user_id" => user_id,
          "device_id" => device_id,
          "algorithms" => ["m.olm.v1.curve25519-aes-sha2"],
          "keys" => %{"ed25519:#{device_id}" => "ed_key_#{device_id}"},
          "signatures" => %{user_id => %{"ed25519:#{device_id}" => "sig_#{device_id}"}}
        },
        "one_time_keys" => %{"curve25519:OTK1" => %{"key" => "otk_for_#{device_id}"}}
      })

    assert conn.status == 200
  end

  defp device_key_rows(user_id, device_id) do
    device_keys =
      Repo.all(
        from(k in "device_keys",
          where: k.user_id == ^user_id and k.device_id == ^device_id,
          select: k.device_id
        )
      )

    otks =
      Repo.all(
        from(k in "one_time_keys",
          where: k.user_id == ^user_id and k.device_id == ^device_id,
          select: k.id
        )
      )

    {length(device_keys), length(otks)}
  end

  test "DELETE /devices/:device_id purges device_keys and one_time_keys for that device" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    login_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/login",
        Jason.encode!(%{
          "type" => "m.login.password",
          "identifier" => %{"user" => alice.user_id},
          "password" => "Test1234!"
        })
      )

    other_device_id = decode(login_conn)["device_id"]
    other_token = decode(login_conn)["access_token"]
    upload_device_keys(other_token, alice.user_id, other_device_id)

    assert device_key_rows(alice.user_id, other_device_id) == {1, 1}

    auth = %{
      "type" => "m.login.password",
      "identifier" => %{"user" => alice.user_id},
      "password" => "Test1234!"
    }

    del_conn =
      authed(alice.token)
      |> jd("/_matrix/client/v3/devices/#{other_device_id}", %{"auth" => auth})

    assert del_conn.status == 200

    assert device_key_rows(alice.user_id, other_device_id) == {0, 0}
  end

  test "delete_devices (bulk) purges key material for each removed device" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    login_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/login",
        Jason.encode!(%{
          "type" => "m.login.password",
          "identifier" => %{"user" => alice.user_id},
          "password" => "Test1234!"
        })
      )

    device2 = decode(login_conn)["device_id"]
    token2 = decode(login_conn)["access_token"]
    upload_device_keys(token2, alice.user_id, device2)

    assert device_key_rows(alice.user_id, device2) == {1, 1}

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/delete_devices", %{
        "devices" => [device2],
        "auth" => %{"type" => "m.login.dummy"}
      })

    assert conn.status == 200
    assert device_key_rows(alice.user_id, device2) == {0, 0}
  end

  test "logout purges the device's key material" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    login_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/login",
        Jason.encode!(%{
          "type" => "m.login.password",
          "identifier" => %{"user" => alice.user_id},
          "password" => "Test1234!"
        })
      )

    other_device_id = decode(login_conn)["device_id"]
    other_token = decode(login_conn)["access_token"]
    upload_device_keys(other_token, alice.user_id, other_device_id)

    assert device_key_rows(alice.user_id, other_device_id) == {1, 1}

    logout_conn = authed(other_token) |> jp("/_matrix/client/v3/logout", %{})
    assert logout_conn.status == 200

    assert device_key_rows(alice.user_id, other_device_id) == {0, 0}
  end
end
