defmodule AxonWeb.TransactionIdProjectionTest do
  use AxonWeb.ConnCase, async: false

  alias AxonWeb.TransactionIdProjection

  defp json_request(conn, :post, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp json_request(conn, :put, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

  defp register(username, opts) do
    conn =
      json_request(build_conn(), :post, "/_matrix/client/v3/register", %{
        "username" => username,
        "password" => "Test1234!",
        "kind" => "user",
        "device_id" => opts["device_id"],
        "refresh_token" => opts["refresh_token"] || false,
        "auth" => %{"type" => "m.login.dummy"}
      })

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp login(username, device_id) do
    conn =
      json_request(build_conn(), :post, "/_matrix/client/v3/login", %{
        "type" => "m.login.password",
        "identifier" => %{"user" => username},
        "password" => "Test1234!",
        "device_id" => device_id
      })

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp create_room(token) do
    conn =
      json_request(authed(token), :post, "/_matrix/client/v3/createRoom", %{
        "preset" => "public_chat"
      })

    assert conn.status == 200
    Jason.decode!(conn.resp_body)["room_id"]
  end

  defp join_room(token, room_id) do
    conn = json_request(authed(token), :post, "/_matrix/client/v3/join/#{room_id}", %{})
    assert conn.status == 200
  end

  defp send_event(token, room_id, txn_id, content \\ %{"body" => "hello"}) do
    conn =
      json_request(
        authed(token),
        :put,
        "/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn_id}",
        content
      )

    assert conn.status == 200
    Jason.decode!(conn.resp_body)["event_id"]
  end

  defp get_event(token, room_id, event_id) do
    conn =
      get(authed(token), "/_matrix/client/v3/rooms/#{room_id}/event/#{URI.encode(event_id)}")

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp sync_event(token, room_id, event_id) do
    conn = get(authed(token), "/_matrix/client/v3/sync?timeout=0")
    assert conn.status == 200

    conn.resp_body
    |> Jason.decode!()
    |> get_in(["rooms", "join", room_id, "timeline", "events"])
    |> Enum.find(&(&1["event_id"] == event_id))
  end

  test "TestTxnInEvent: transaction_id is projected only to the sending user and device" do
    suffix = System.unique_integer([:positive])
    alice = register("txn_get_alice_#{suffix}", %{"device_id" => "ALICE_SEND"})
    alice_other = login(alice["user_id"], "ALICE_OTHER")
    bob = register("txn_get_bob_#{suffix}", %{"device_id" => "BOB_DEVICE"})

    room_id = create_room(alice["access_token"])
    join_room(bob["access_token"], room_id)

    txn_id = "txn-get-#{suffix}"
    event_id = send_event(alice["access_token"], room_id, txn_id)

    sender_event = get_event(alice["access_token"], room_id, event_id)
    assert get_in(sender_event, ["unsigned", "transaction_id"]) == txn_id

    other_device_event = get_event(alice_other["access_token"], room_id, event_id)
    refute get_in(other_device_event, ["unsigned", "transaction_id"])

    other_user_event = get_event(bob["access_token"], room_id, event_id)
    refute get_in(other_user_event, ["unsigned", "transaction_id"])
  end

  test "TestTxnScopeOnLocalEcho: sync projects transaction_id only to the sending device and merges unsigned" do
    suffix = System.unique_integer([:positive])
    alice = register("txn_sync_alice_#{suffix}", %{"device_id" => "ALICE_SEND"})
    alice_other = login(alice["user_id"], "ALICE_OTHER")
    bob = register("txn_sync_bob_#{suffix}", %{"device_id" => "BOB_DEVICE"})

    room_id = create_room(alice["access_token"])
    join_room(bob["access_token"], room_id)

    txn_id = "txn-sync-#{suffix}"
    event_id = send_event(alice["access_token"], room_id, txn_id)

    sender_event = sync_event(alice["access_token"], room_id, event_id)
    assert sender_event["unsigned"]["membership"] == "join"
    assert sender_event["unsigned"]["transaction_id"] == txn_id

    other_device_event = sync_event(alice_other["access_token"], room_id, event_id)
    assert other_device_event["unsigned"]["membership"] == "join"
    refute other_device_event["unsigned"]["transaction_id"]

    other_user_event = sync_event(bob["access_token"], room_id, event_id)
    assert other_user_event["unsigned"]["membership"] == "join"
    refute other_user_event["unsigned"]["transaction_id"]
  end

  test "TestTxnIdWithRefreshToken: refreshed access token keeps device-scoped projection and send behavior" do
    suffix = System.unique_integer([:positive])

    alice =
      register("txn_refresh_alice_#{suffix}", %{
        "device_id" => "ALICE_REFRESH",
        "refresh_token" => true
      })

    room_id = create_room(alice["access_token"])
    txn_id = "txn-refresh-#{suffix}"
    event_id = send_event(alice["access_token"], room_id, txn_id)

    refresh_conn =
      json_request(build_conn(), :post, "/_matrix/client/v3/refresh", %{
        "refresh_token" => alice["refresh_token"]
      })

    assert refresh_conn.status == 200
    refreshed_access_token = Jason.decode!(refresh_conn.resp_body)["access_token"]

    synced_event = sync_event(refreshed_access_token, room_id, event_id)
    assert synced_event["unsigned"]["membership"] == "join"
    assert synced_event["unsigned"]["transaction_id"] == txn_id

    assert send_event(refreshed_access_token, room_id, txn_id, %{"body" => "ignored retry"}) ==
             event_id
  end

  test "messages and context project only the requesting device's transaction id" do
    suffix = System.unique_integer([:positive])
    alice = register("txn_pages_#{suffix}", %{"device_id" => "SENDER"})
    other = login(alice["user_id"], "OTHER")
    room_id = create_room(alice["access_token"])
    txn_id = "txn-pages-#{suffix}"
    event_id = send_event(alice["access_token"], room_id, txn_id)

    for {path, selector} <- [
          {"/_matrix/client/v3/rooms/#{room_id}/messages?dir=b&limit=100", &hd(&1["chunk"])},
          {"/_matrix/client/v3/rooms/#{room_id}/context/#{URI.encode(event_id)}", & &1["event"]}
        ] do
      sender =
        get(authed(alice["access_token"]), path)
        |> then(&Jason.decode!(&1.resp_body))
        |> selector.()

      assert sender["unsigned"]["transaction_id"] == txn_id

      leaked =
        get(authed(other["access_token"]), path)
        |> then(&Jason.decode!(&1.resp_body))
        |> selector.()

      refute get_in(leaked, ["unsigned", "transaction_id"])
    end
  end

  test "relations project transaction ids in the chunk without leaking to another device" do
    suffix = System.unique_integer([:positive])
    alice = register("txn_rel_#{suffix}", %{"device_id" => "SENDER"})
    other = login(alice["user_id"], "OTHER")
    room_id = create_room(alice["access_token"])
    root_id = send_event(alice["access_token"], room_id, "root-#{suffix}")
    txn_id = "reply-#{suffix}"

    reply_id =
      send_event(alice["access_token"], room_id, txn_id, %{
        "body" => "reply",
        "m.relates_to" => %{"rel_type" => "m.reference", "event_id" => root_id}
      })

    path = "/_matrix/client/v1/rooms/#{room_id}/relations/#{URI.encode(root_id)}"
    sender = get(authed(alice["access_token"]), path) |> then(&Jason.decode!(&1.resp_body))
    projected = Enum.find(sender["chunk"], &(&1["event_id"] == reply_id))
    assert projected["unsigned"]["transaction_id"] == txn_id

    leaked = get(authed(other["access_token"]), path) |> then(&Jason.decode!(&1.resp_body))

    refute leaked["chunk"]
           |> Enum.find(&(&1["event_id"] == reply_id))
           |> get_in(["unsigned", "transaction_id"])
  end

  test "projection never treats arbitrary event content as an event envelope" do
    response = %{
      "event_id" => "$outer",
      "content" => %{"event_id" => "$inner", "unsigned" => %{"safe" => true}}
    }

    AxonCore.Repo.insert_all("client_txns", [
      %{
        user_id: "@projection:localhost",
        device_id: "DEVICE",
        txn_id: "inner-txn",
        request_scope: "test",
        event_id: "$inner",
        inserted_at: DateTime.utc_now(:microsecond)
      }
    ])

    projected = TransactionIdProjection.project(response, "@projection:localhost", "DEVICE")
    refute get_in(projected, ["content", "unsigned", "transaction_id"])
  end

  test "archived limit:0 projection covers both state and timeline event slots" do
    user_id = "@archive_projection:localhost"
    device_id = "ARCHIVE_DEVICE"

    AxonCore.Repo.insert_all("client_txns", [
      %{
        user_id: user_id,
        device_id: device_id,
        txn_id: "state-txn",
        request_scope: "test",
        event_id: "$archived-state",
        inserted_at: DateTime.utc_now(:microsecond)
      },
      %{
        user_id: user_id,
        device_id: device_id,
        txn_id: "timeline-txn",
        request_scope: "test",
        event_id: "$archived-timeline",
        inserted_at: DateTime.utc_now(:microsecond)
      }
    ])

    rooms = %{
      "join" => %{},
      "leave" => %{
        "!archived:localhost" => %{
          "timeline" => %{"events" => [%{"event_id" => "$archived-timeline"}]},
          "state" => %{"events" => [%{"event_id" => "$archived-state"}]}
        }
      }
    }

    projected = TransactionIdProjection.project_sync_rooms(rooms, user_id, device_id)

    assert get_in(projected, [
             "leave",
             "!archived:localhost",
             "timeline",
             "events",
             Access.at(0),
             "unsigned",
             "transaction_id"
           ]) ==
             "timeline-txn"

    assert get_in(projected, [
             "leave",
             "!archived:localhost",
             "state",
             "events",
             Access.at(0),
             "unsigned",
             "transaction_id"
           ]) ==
             "state-txn"
  end
end
