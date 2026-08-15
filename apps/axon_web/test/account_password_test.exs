defmodule AxonWeb.AccountPasswordTest do
  @moduledoc """
  `POST /account/password` (Complement's `TestChangePasswordPushers`):
  changing password logs out every device but the one making the request
  (`logout_devices` defaults `true`), and a pusher belongs to a device —
  so a pusher registered on a device that gets logged out must be
  deleted along with it, while a pusher on the device performing the
  password change must survive.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  defp login(username, password, opts \\ %{}) do
    body = Map.merge(%{"type" => "m.login.password", "user" => username, "password" => password}, opts)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/_matrix/client/v3/login", Jason.encode!(body))

    assert conn.status == 200
    body = decode(conn)
    %{token: body["access_token"], user_id: body["user_id"]}
  end

  defp set_pusher(token, pushkey) do
    conn =
      authed(token)
      |> jp("/_matrix/client/v3/pushers/set", %{
        "kind" => "http",
        "app_id" => "complement",
        "app_display_name" => "app",
        "device_display_name" => "device",
        "pushkey" => pushkey,
        "lang" => "en",
        "data" => %{"url" => "https://dummy.url/_matrix/push/v1/notify"}
      })

    assert conn.status == 200
  end

  defp change_password(token, username, old_password, new_password) do
    authed(token)
    |> jp("/_matrix/client/v3/account/password", %{
      "new_password" => new_password,
      "auth" => %{
        "type" => "m.login.password",
        "password" => old_password,
        "identifier" => %{"type" => "m.id.user", "user" => username}
      }
    })
  end

  defp pushers(token) do
    authed(token) |> get("/_matrix/client/v3/pushers") |> decode() |> Map.fetch!("pushers")
  end

  test "pushers on a different device are deleted on password change, same-device pusher survives" do
    username = "acctpw_#{System.unique_integer([:positive])}"
    alice = register(username)

    other_session = login(username, "Test1234!")
    set_pusher(other_session.token, "other_device_key")
    set_pusher(alice.token, "same_device_key")

    conn = change_password(alice.token, username, "Test1234!", "NewPassword1!")
    assert conn.status == 200

    remaining = pushers(alice.token)
    assert length(remaining) == 1
    assert hd(remaining)["pushkey"] == "same_device_key"
  end
end
