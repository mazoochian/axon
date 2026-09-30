defmodule AxonWeb.PusherControllerTest do
  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  defp set_pusher(token, data) do
    authed(token)
    |> jp("/_matrix/client/v3/pushers/set", %{
      "kind" => "http",
      "app_id" => "com.example.app",
      "app_display_name" => "App",
      "device_display_name" => "Device",
      "pushkey" => "pk",
      "lang" => "en",
      "data" => data
    })
  end

  test "an http pusher url must be http(s) with the spec notify path" do
    user = register("pusher_url_#{System.unique_integer([:positive])}")

    for url <- [
          "http://169.254.169.254/latest/meta-data",
          "ftp://push.example.com/_matrix/push/v1/notify",
          nil
        ] do
      conn = set_pusher(user.token, %{"url" => url})
      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_INVALID_PARAM"
    end

    assert set_pusher(user.token, "not a map").status == 400

    assert set_pusher(user.token, %{"url" => "https://push.example.com/_matrix/push/v1/notify"}).status ==
             200
  end
end
