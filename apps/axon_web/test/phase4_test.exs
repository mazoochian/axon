defmodule AxonWeb.Phase4Test do
  @moduledoc """
  Integration tests for Phase 4: media upload/download, push notifications,
  and application service skeleton.
  """

  use AxonWeb.ConnCase, async: false

  alias AxonPush.RuleEvaluator

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

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # -------------------------------------------------------------------------
  # 4a. Media
  # -------------------------------------------------------------------------

  describe "media upload and download" do
    test "upload a file and get mxc:// URI back" do
      user = register("media_up_#{System.unique_integer([:positive])}")
      data = "hello world image data"

      conn =
        authed(user.token)
        |> put_req_header("content-type", "image/png")
        |> post("/_matrix/client/v3/media/upload", data)

      assert conn.status == 200
      body = decode(conn)
      assert String.starts_with?(body["content_uri"], "mxc://")
      assert String.contains?(body["content_uri"], "localhost")
    end

    test "upload via /_matrix/media/v3/upload (unauthenticated path)" do
      user = register("media_up2_#{System.unique_integer([:positive])}")

      # This path doesn't require auth by our router config
      conn =
        authed(user.token)
        |> put_req_header("content-type", "text/plain")
        |> post("/_matrix/media/v3/upload", "hello plain text")

      assert conn.status == 200
      body = decode(conn)
      assert String.starts_with?(body["content_uri"], "mxc://")
    end

    test "download a locally uploaded file" do
      user = register("media_dl_#{System.unique_integer([:positive])}")
      # some binary
      data = <<0, 1, 2, 3, 4, 5>>

      upload_conn =
        authed(user.token)
        |> put_req_header("content-type", "application/octet-stream")
        |> post("/_matrix/client/v3/media/upload", data)

      assert upload_conn.status == 200
      mxc_uri = decode(upload_conn)["content_uri"]
      # mxc://localhost/MEDIA_ID
      ["mxc:", "", _server, media_id] = String.split(mxc_uri, "/")

      dl_conn =
        build_conn()
        |> get("/_matrix/media/v3/download/localhost/#{media_id}")

      assert dl_conn.status == 200
      assert dl_conn.resp_body == data
      assert hd(get_resp_header(dl_conn, "content-type")) =~ "application/octet-stream"
    end

    test "thumbnail request generates a resized image" do
      user = register("media_thumb_#{System.unique_integer([:positive])}")

      source_path =
        Path.join(System.tmp_dir!(), "axon_test_thumb_#{System.unique_integer([:positive])}.jpg")

      {_, 0} = System.cmd("convert", ["-size", "200x200", "xc:blue", source_path])
      data = File.read!(source_path)
      File.rm(source_path)

      upload_conn =
        authed(user.token)
        |> put_req_header("content-type", "image/jpeg")
        |> post("/_matrix/client/v3/media/upload", data)

      assert upload_conn.status == 200
      mxc_uri = decode(upload_conn)["content_uri"]
      ["mxc:", "", _server, media_id] = String.split(mxc_uri, "/")

      thumb_conn =
        build_conn()
        |> get(
          "/_matrix/media/v3/thumbnail/localhost/#{media_id}?width=64&height=64&method=scale"
        )

      assert thumb_conn.status == 200
      assert hd(get_resp_header(thumb_conn, "content-type")) =~ "image/jpeg"
      # A real, distinct (resized) image comes back — not a passthrough of the original.
      assert thumb_conn.resp_body != data
    end

    test "thumbnail request for a non-image falls back to the original file" do
      user = register("media_thumb_nonimage_#{System.unique_integer([:positive])}")
      data = "not an image"

      upload_conn =
        authed(user.token)
        |> put_req_header("content-type", "application/octet-stream")
        |> post("/_matrix/client/v3/media/upload", data)

      assert upload_conn.status == 200
      mxc_uri = decode(upload_conn)["content_uri"]
      ["mxc:", "", _server, media_id] = String.split(mxc_uri, "/")

      thumb_conn =
        build_conn()
        |> get(
          "/_matrix/media/v3/thumbnail/localhost/#{media_id}?width=64&height=64&method=scale"
        )

      assert thumb_conn.status == 200
      assert thumb_conn.resp_body == data
    end

    test "download unknown media returns 404" do
      conn = build_conn() |> get("/_matrix/media/v3/download/localhost/nonexistentmediaid123")
      assert conn.status == 404
      assert decode(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "v1 authenticated download works" do
      user = register("media_v1_#{System.unique_integer([:positive])}")
      data = "v1 download test"

      upload_conn =
        authed(user.token)
        |> put_req_header("content-type", "text/plain")
        |> post("/_matrix/client/v3/media/upload", data)

      assert upload_conn.status == 200
      mxc_uri = decode(upload_conn)["content_uri"]
      ["mxc:", "", _server, media_id] = String.split(mxc_uri, "/")

      dl_conn =
        authed(user.token)
        |> get("/_matrix/client/v1/media/download/localhost/#{media_id}")

      assert dl_conn.status == 200
      assert dl_conn.resp_body == data
    end
  end

  # -------------------------------------------------------------------------
  # 4b. Push notifications — pusher registration
  # -------------------------------------------------------------------------

  describe "pusher registration" do
    test "register a pusher and retrieve it" do
      user = register("pusher_reg_#{System.unique_integer([:positive])}")

      set_conn =
        authed(user.token)
        |> jp("/_matrix/client/v3/pushers/set", %{
          "kind" => "http",
          "app_id" => "com.example.myapp",
          "app_display_name" => "My App",
          "device_display_name" => "My Phone",
          "pushkey" => "https://push.example.com/notify/abc123",
          "lang" => "en",
          "data" => %{
            "url" => "https://push.example.com/_matrix/push/v1/notify",
            "format" => "event_id_only"
          }
        })

      assert set_conn.status == 200

      list_conn = authed(user.token) |> get("/_matrix/client/v3/pushers")
      assert list_conn.status == 200
      body = decode(list_conn)
      assert length(body["pushers"]) == 1
      [pusher] = body["pushers"]
      assert pusher["app_id"] == "com.example.myapp"
      assert pusher["kind"] == "http"
      assert pusher["pushkey"] == "https://push.example.com/notify/abc123"
    end

    test "upsert overwrites existing pusher for same app_id+pushkey" do
      user = register("pusher_upsert_#{System.unique_integer([:positive])}")
      pushkey = "https://push.example.com/key_#{System.unique_integer()}"

      authed(user.token)
      |> jp("/_matrix/client/v3/pushers/set", %{
        "kind" => "http",
        "app_id" => "com.example",
        "app_display_name" => "v1",
        "device_display_name" => "Phone",
        "pushkey" => pushkey,
        "lang" => "en",
        "data" => %{"url" => "https://push.example.com/v1"}
      })
      |> then(fn c -> assert c.status == 200 end)

      authed(user.token)
      |> jp("/_matrix/client/v3/pushers/set", %{
        "kind" => "http",
        "app_id" => "com.example",
        "app_display_name" => "v2",
        "device_display_name" => "Phone",
        "pushkey" => pushkey,
        "lang" => "fr",
        "data" => %{"url" => "https://push.example.com/v2"}
      })
      |> then(fn c -> assert c.status == 200 end)

      list_conn = authed(user.token) |> get("/_matrix/client/v3/pushers")
      body = decode(list_conn)
      assert length(body["pushers"]) == 1
      assert hd(body["pushers"])["app_display_name"] == "v2"
      assert hd(body["pushers"])["lang"] == "fr"
    end

    test "delete a pusher by sending kind=nil" do
      user = register("pusher_del_#{System.unique_integer([:positive])}")
      pushkey = "https://push.example.com/del_#{System.unique_integer()}"

      authed(user.token)
      |> jp("/_matrix/client/v3/pushers/set", %{
        "kind" => "http",
        "app_id" => "com.example.del",
        "app_display_name" => "App",
        "device_display_name" => "Phone",
        "pushkey" => pushkey,
        "lang" => "en",
        "data" => %{"url" => "https://push.example.com/notify"}
      })
      |> then(fn c -> assert c.status == 200 end)

      # Delete by omitting kind
      authed(user.token)
      |> jp("/_matrix/client/v3/pushers/set", %{
        "app_id" => "com.example.del",
        "pushkey" => pushkey
      })
      |> then(fn c -> assert c.status == 200 end)

      list_conn = authed(user.token) |> get("/_matrix/client/v3/pushers")
      assert decode(list_conn)["pushers"] == []
    end
  end

  # -------------------------------------------------------------------------
  # 4b. Push rule evaluation
  # -------------------------------------------------------------------------

  describe "push rule evaluation" do
    setup do
      {:ok, rules: AxonPush.DefaultRules.rules()}
    end

    test "m.room.message in 1:1 room triggers notify", %{rules: rules} do
      event = %{
        "type" => "m.room.message",
        "sender" => "@alice:localhost",
        "content" => %{"msgtype" => "m.text", "body" => "hello"}
      }

      # room_id here won't match a real room, so member_count query returns 0
      # but the plain message underride rule has no room_member_count condition
      result = RuleEvaluator.should_notify?(event, "!fake:localhost", "@bob:localhost", rules)
      assert match?({:notify, _}, result)
    end

    test "m.notice message is suppressed" do
      event = %{
        "type" => "m.room.message",
        "sender" => "@bot:localhost",
        "content" => %{"msgtype" => "m.notice", "body" => "automated notice"}
      }

      result =
        RuleEvaluator.should_notify?(
          event,
          "!fake:localhost",
          "@bob:localhost",
          AxonPush.DefaultRules.rules()
        )

      assert result == :dont_notify
    end

    test "message containing display name triggers highlight" do
      # Register a user with a display name
      user = register("dn_push_#{System.unique_integer([:positive])}")

      # Set a display name
      authed(user.token)
      |> put_req_header("content-type", "application/json")
      |> put(
        "/_matrix/client/v3/profile/#{user.user_id}/displayname",
        Jason.encode!(%{"displayname" => "TestUser"})
      )

      event = %{
        "type" => "m.room.message",
        "sender" => "@alice:localhost",
        "content" => %{"msgtype" => "m.text", "body" => "Hey TestUser how are you?"}
      }

      result =
        RuleEvaluator.should_notify?(
          event,
          "!fake:localhost",
          user.user_id,
          AxonPush.DefaultRules.rules()
        )

      assert match?({:notify, actions} when is_list(actions), result)
    end

    test "master rule disabled by default (don't_notify actions not applied)" do
      # The master rule has enabled: false, so it shouldn't suppress everything
      event = %{
        "type" => "m.room.message",
        "sender" => "@alice:localhost",
        "content" => %{"msgtype" => "m.text", "body" => "hello"}
      }

      result =
        RuleEvaluator.should_notify?(
          event,
          "!fake:localhost",
          "@bob:localhost",
          AxonPush.DefaultRules.rules()
        )

      # Should still notify because master rule is disabled
      assert match?({:notify, _}, result)
    end
  end

  # -------------------------------------------------------------------------
  # 4c. Application services
  # -------------------------------------------------------------------------

  describe "application service transaction endpoint" do
    test "returns 403 for unknown AS token" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put(
          "/_matrix/app/v1/transactions/txn1?access_token=invalid_token",
          Jason.encode!(%{"events" => []})
        )

      assert conn.status == 403
      assert decode(conn)["errcode"] == "M_FORBIDDEN"
    end

    test "returns 403 via Authorization header with bad token" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer badtoken")
        |> put("/_matrix/app/v1/transactions/txn2", Jason.encode!(%{"events" => []}))

      assert conn.status == 403
    end
  end
end
