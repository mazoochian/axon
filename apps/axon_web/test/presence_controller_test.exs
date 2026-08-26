defmodule AxonWeb.PresenceControllerTest do
  @moduledoc "Tests presence get/put endpoints."

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
    %{token: body["access_token"], user_id: body["user_id"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp jpu(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "put_status then get_status round-trips presence and status_msg" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    put_conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/presence/#{alice.user_id}/status", %{
        "presence" => "online",
        "status_msg" => "hi"
      })

    assert put_conn.status == 200

    get_conn = authed(alice.token) |> get("/_matrix/client/v3/presence/#{alice.user_id}/status")
    body = decode(get_conn)
    assert body["presence"] == "online"
    assert body["status_msg"] == "hi"
  end

  test "cannot set another user's presence" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/presence/#{bob.user_id}/status", %{"presence" => "online"})

    assert conn.status == 403
  end

  test "an invalid presence value is rejected" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/presence/#{alice.user_id}/status", %{"presence" => "bogus"})

    assert conn.status == 400
  end

  defp jp(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))

  # Alice creates a room and invites Bob, who joins — the "shares a joined
  # room" relationship presence visibility is gated on.
  defp room_shared_by(alice, bob) do
    create_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/createRoom", %{"invite" => [bob.user_id]})

    assert create_conn.status == 200
    room_id = decode(create_conn)["room_id"]

    join_conn = authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
    assert join_conn.status == 200

    room_id
  end

  # Bob has never called PUT .../status, so his presence is whatever the
  # server derives from activity alone — not an error and not absent. (It
  # can't be asserted as "offline" any more: joining the shared room this
  # check now requires is itself activity, which marks him online.)
  test "getting presence for a user who's never set any returns a default rather than erroring" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    room_shared_by(alice, bob)

    conn = authed(alice.token) |> get("/_matrix/client/v3/presence/#{bob.user_id}/status")
    assert conn.status == 200
    assert decode(conn)["presence"] in ["offline", "online", "unavailable"]
  end

  # Regression for the cross-user presence leak: this endpoint used to
  # return any user's presence to any authenticated caller, with no
  # relationship check at all — an activity tracker (online/offline,
  # last_active_ago, status_msg) over every account on the server.
  describe "presence visibility" do
    test "a user sharing no room with the target cannot read their presence" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      mallory = register("mallory_#{System.unique_integer([:positive])}")

      # Alice is demonstrably online with a status message, so there is
      # something real to leak.
      assert authed(alice.token)
             |> jpu("/_matrix/client/v3/presence/#{alice.user_id}/status", %{
               "presence" => "online",
               "status_msg" => "at my desk"
             })
             |> Map.fetch!(:status) == 200

      conn = authed(mallory.token) |> get("/_matrix/client/v3/presence/#{alice.user_id}/status")

      assert conn.status == 403
      body = decode(conn)
      assert body["errcode"] == "M_FORBIDDEN"
      # Nothing about Alice's actual state comes back with the refusal.
      refute Map.has_key?(body, "presence")
      refute Map.has_key?(body, "status_msg")
      refute Map.has_key?(body, "last_active_ago")
    end

    test "a user sharing a joined room with the target can read their presence" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")
      room_shared_by(alice, bob)

      assert authed(alice.token)
             |> jpu("/_matrix/client/v3/presence/#{alice.user_id}/status", %{
               "presence" => "online",
               "status_msg" => "at my desk"
             })
             |> Map.fetch!(:status) == 200

      conn = authed(bob.token) |> get("/_matrix/client/v3/presence/#{alice.user_id}/status")

      assert conn.status == 200
      body = decode(conn)
      assert body["presence"] == "online"
      assert body["status_msg"] == "at my desk"
    end

    test "a user can always read their own presence" do
      alice = register("alice_#{System.unique_integer([:positive])}")

      conn = authed(alice.token) |> get("/_matrix/client/v3/presence/#{alice.user_id}/status")
      assert conn.status == 200
      assert decode(conn)["presence"] in ["offline", "online", "unavailable"]
    end

    test "an invited-but-not-joined user is not enough to share presence" do
      alice = register("alice_#{System.unique_integer([:positive])}")
      bob = register("bob_#{System.unique_integer([:positive])}")

      create_conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/createRoom", %{"invite" => [bob.user_id]})

      assert create_conn.status == 200

      conn = authed(bob.token) |> get("/_matrix/client/v3/presence/#{alice.user_id}/status")
      assert conn.status == 403
      assert decode(conn)["errcode"] == "M_FORBIDDEN"
    end
  end

  # `?set_presence=` on /sync (Complement's TestPresence "Presence can be
  # set from sync") — previously read nowhere, so a client setting presence
  # this way (rather than via PUT .../status) had no effect at all.
  test "?set_presence= on /sync updates the user's presence" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    sync_conn =
      authed(alice.token) |> get("/_matrix/client/v3/sync?timeout=0&set_presence=unavailable")

    assert sync_conn.status == 200

    status_conn =
      authed(alice.token) |> get("/_matrix/client/v3/presence/#{alice.user_id}/status")

    assert decode(status_conn)["presence"] == "unavailable"
  end

  test "an invalid ?set_presence= value on /sync is silently ignored, not an error" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    conn = authed(alice.token) |> get("/_matrix/client/v3/sync?timeout=0&set_presence=bogus")
    assert conn.status == 200
  end
end
