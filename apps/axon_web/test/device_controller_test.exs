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
      |> post("/_matrix/client/v3/register", Jason.encode!(%{
        "username" => username,
        "password" => "Test1234!",
        "kind" => "user",
        "auth" => %{"type" => "m.login.dummy"}
      }))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    %{token: body["access_token"], user_id: body["user_id"], device_id: body["device_id"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
  defp jp(conn, path, body), do: conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))
  defp jpu(conn, path, body), do: conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))
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

  test "show for an unknown device_id 404s" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/devices/NONEXISTENT")
    assert conn.status == 404
  end

  test "update sets the display_name" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> jpu("/_matrix/client/v3/devices/#{alice.device_id}", %{"display_name" => "My Phone"})
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

  defp jd(conn, path, body), do: conn |> put_req_header("content-type", "application/json") |> delete(path, Jason.encode!(body))

  test "delete succeeds with correct password UIA" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    login_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/_matrix/client/v3/login", Jason.encode!(%{"type" => "m.login.password", "identifier" => %{"user" => alice.user_id}, "password" => "Test1234!"}))

    other_device_id = decode(login_conn)["device_id"]
    auth = %{"type" => "m.login.password", "identifier" => %{"user" => alice.user_id}, "password" => "Test1234!"}

    del_conn = authed(alice.token) |> jd("/_matrix/client/v3/devices/#{other_device_id}", %{"auth" => auth})
    assert del_conn.status == 200

    show_conn = authed(alice.token) |> get("/_matrix/client/v3/devices/#{other_device_id}")
    assert show_conn.status == 404
  end

  test "delete with wrong password UIA is rejected" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    auth = %{"type" => "m.login.password", "identifier" => %{"user" => alice.user_id}, "password" => "WrongPassword!"}

    conn = authed(alice.token) |> jd("/_matrix/client/v3/devices/#{alice.device_id}", %{"auth" => auth})
    assert conn.status == 401
  end

  test "delete_devices (bulk) removes multiple devices with m.login.dummy" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    login_conn = build_conn() |> put_req_header("content-type", "application/json") |> post("/_matrix/client/v3/login", Jason.encode!(%{"type" => "m.login.password", "identifier" => %{"user" => alice.user_id}, "password" => "Test1234!"}))
    device2 = decode(login_conn)["device_id"]

    conn = authed(alice.token) |> jp("/_matrix/client/v3/delete_devices", %{"devices" => [device2], "auth" => %{"type" => "m.login.dummy"}})
    assert conn.status == 200

    show_conn = authed(alice.token) |> get("/_matrix/client/v3/devices/#{device2}")
    assert show_conn.status == 404
  end
end
