defmodule AxonWeb.E2E.PushPipelineFlowTest do
  @moduledoc """
  End-to-end push flow through the REAL HTTP-facing pieces (`PusherController`,
  `EventController`/`RoomProcess`, `AxonPush.Dispatcher`), unlike
  `axon_push/test/dispatcher_test.exs` which calls `Dispatcher.dispatch_event/2`
  directly against hand-inserted DB rows. Registers a pusher via the client
  API, sends a real room message via the client API, and asserts delivery to
  a fake HTTP push gateway — plus that muted event types and the sender
  itself are correctly excluded, and that push rules (mute a room) suppress
  delivery end to end.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonPush.FakePusherGateway

  @port 18_600

  setup do
    start_supervised!({FakePusherGateway, port: @port})
    :ok
  end

  defp set_pusher(token, app_id) do
    conn =
      authed(token)
      |> jp("/_matrix/client/v3/pushers/set", %{
        "kind" => "http",
        "app_id" => app_id,
        "app_display_name" => "Test App",
        "device_display_name" => "Test Device",
        "pushkey" => "pushkey_#{System.unique_integer([:positive])}",
        "lang" => "en",
        "data" => %{"url" => "http://127.0.0.1:#{@port}/_matrix/push/v1/notify"},
        "append" => false
      })

    assert conn.status == 200
  end

  defp wait_for_delivery(retries \\ 50) do
    case FakePusherGateway.received(@port) do
      [] when retries > 0 ->
        Process.sleep(20)
        wait_for_delivery(retries - 1)

      received ->
        received
    end
  end

  defp assert_no_delivery do
    Process.sleep(100)
    assert FakePusherGateway.received(@port) == []
  end

  test "registering a pusher via the API and sending a real message delivers an HTTP push" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    assert authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{}) |> Map.get(:status) ==
             200

    set_pusher(bob.token, "com.example.e2e")

    event_id =
      send_event(alice.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "hello bob"
      })

    [payload] = wait_for_delivery()
    notification = payload["notification"]
    assert notification["event_id"] == event_id
    assert notification["room_id"] == room_id
    assert notification["sender"] == alice.user_id
  end

  test "the sender never gets pushed their own message, even with a registered pusher" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})
    set_pusher(alice.token, "com.example.selfpush")

    send_event(alice.token, room_id, "m.room.message", %{
      "msgtype" => "m.text",
      "body" => "talking to myself"
    })

    assert_no_delivery()
  end

  test "clearing a pusher (kind omitted) stops further delivery" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    assert authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{}) |> Map.get(:status) ==
             200

    pushkey = "pushkey_#{System.unique_integer([:positive])}"

    setup_conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/pushers/set", %{
        "kind" => "http",
        "app_id" => "com.example.clearme",
        "app_display_name" => "App",
        "device_display_name" => "Device",
        "pushkey" => pushkey,
        "lang" => "en",
        "data" => %{"url" => "http://127.0.0.1:#{@port}/_matrix/push/v1/notify"}
      })

    assert setup_conn.status == 200

    send_event(alice.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "first"})

    delivered_before_clear = wait_for_delivery()
    assert delivered_before_clear != []
    count_before = length(delivered_before_clear)

    clear_conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/pushers/set", %{
        "app_id" => "com.example.clearme",
        "pushkey" => pushkey
      })

    assert clear_conn.status == 200

    pushers_conn = authed(bob.token) |> get("/_matrix/client/v3/pushers")
    refute Enum.any?(decode(pushers_conn)["pushers"], &(&1["app_id"] == "com.example.clearme"))

    send_event(alice.token, room_id, "m.room.message", %{
      "msgtype" => "m.text",
      "body" => "second, after clearing"
    })

    # No NEW delivery arrives once the pusher is cleared (the gateway already
    # holds the first, pre-clear delivery, so this must be a delta check).
    Process.sleep(100)
    assert length(FakePusherGateway.received(@port)) == count_before
  end

  test "a room-kind push rule muting a room suppresses delivery for messages in that room" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    assert authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{}) |> Map.get(:status) ==
             200

    set_pusher(bob.token, "com.example.muteroom")

    mute_conn =
      authed(bob.token)
      |> jpu("/_matrix/client/v3/pushrules/global/room/#{room_id}", %{
        "actions" => ["dont_notify"]
      })

    assert mute_conn.status == 200

    send_event(alice.token, room_id, "m.room.message", %{
      "msgtype" => "m.text",
      "body" => "should be muted"
    })

    assert_no_delivery()
  end
end
