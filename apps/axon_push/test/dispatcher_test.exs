defmodule AxonPush.DispatcherTest do
  @moduledoc """
  Tests `AxonPush.Dispatcher.dispatch_event/2`'s real outbound HTTP delivery
  against a fake pusher gateway (`AxonPush.FakePusherGateway`), and its
  push-rule-aware muting behavior.
  """

  use AxonPush.DataCase, async: false

  alias AxonPush.{Dispatcher, FakePusherGateway}

  @room "!room:localhost"
  @sender "@alice:localhost"
  @recipient "@bob:localhost"
  @port 18_500

  setup do
    start_supervised!({FakePusherGateway, port: @port})

    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "users",
      [
        %{user_id: @sender, localpart: "alice", is_guest: false, deactivated: false, admin: false, inserted_at: now, updated_at: now},
        %{user_id: @recipient, localpart: "bob", is_guest: false, deactivated: false, admin: false, inserted_at: now, updated_at: now}
      ],
      on_conflict: :nothing
    )

    Repo.insert_all(
      "rooms",
      [%{room_id: @room, version: "10", creator: @sender, is_public: false, inserted_at: now, updated_at: now}],
      on_conflict: :nothing
    )

    for u <- [@sender, @recipient] do
      Repo.insert_all(
        "room_memberships",
        [%{room_id: @room, user_id: u, membership: "join", event_id: "$#{System.unique_integer([:positive])}", sender: u, inserted_at: now, updated_at: now}],
        on_conflict: {:replace, [:membership]},
        conflict_target: [:room_id, :user_id]
      )
    end

    :ok
  end

  defp register_pusher(user_id, app_id \\ "com.example.app") do
    Repo.insert_all(
      "pushers",
      [
        %{
          user_id: user_id,
          device_id: "DEV1",
          kind: "http",
          app_id: app_id,
          app_display_name: "Test App",
          device_display_name: "Test Device",
          pushkey: "pushkey_#{System.unique_integer([:positive])}",
          lang: "en",
          data: %{"url" => "http://127.0.0.1:#{@port}/_matrix/push/v1/notify"},
          enabled: true
        }
      ],
      on_conflict: :nothing
    )
  end

  defp wait_for_delivery(retries \\ 30) do
    case FakePusherGateway.received(@port) do
      [] when retries > 0 ->
        Process.sleep(20)
        wait_for_delivery(retries - 1)

      received ->
        received
    end
  end

  test "dispatches an HTTP push to a registered pusher for a matching event" do
    register_pusher(@recipient)

    event = %{"event_id" => "$abc", "type" => "m.room.message", "sender" => @sender, "content" => %{"msgtype" => "m.text", "body" => "hello"}}
    Dispatcher.dispatch_event(event, @room)

    [payload] = wait_for_delivery()
    notification = payload["notification"]
    assert notification["event_id"] == "$abc"
    assert notification["room_id"] == @room
    assert notification["sender"] == @sender
    assert [%{"app_id" => "com.example.app"}] = notification["devices"]
  end

  test "never pushes to the sender of the event" do
    register_pusher(@sender)

    event = %{"event_id" => "$xyz", "type" => "m.room.message", "sender" => @sender, "content" => %{"msgtype" => "m.text", "body" => "hi"}}
    Dispatcher.dispatch_event(event, @room)

    # Give the fire-and-forget task a moment; nothing should ever arrive.
    Process.sleep(100)
    assert FakePusherGateway.received(@port) == []
  end

  test "does not dispatch for a muted event type (m.notice suppressed by default rules)" do
    register_pusher(@recipient)

    event = %{"event_id" => "$n1", "type" => "m.room.message", "sender" => @sender, "content" => %{"msgtype" => "m.notice", "body" => "automated"}}
    Dispatcher.dispatch_event(event, @room)

    Process.sleep(100)
    assert FakePusherGateway.received(@port) == []
  end

  test "a recipient with no registered pusher never gets an HTTP request" do
    event = %{"event_id" => "$np", "type" => "m.room.message", "sender" => @sender, "content" => %{"msgtype" => "m.text", "body" => "hi"}}
    Dispatcher.dispatch_event(event, @room)

    Process.sleep(100)
    assert FakePusherGateway.received(@port) == []
  end

  test "a disabled pusher is not delivered to" do
    Repo.insert_all(
      "pushers",
      [
        %{
          user_id: @recipient,
          device_id: "DEV2",
          kind: "http",
          app_id: "com.example.disabled",
          app_display_name: "App",
          device_display_name: "Device",
          pushkey: "pk_#{System.unique_integer([:positive])}",
          lang: "en",
          data: %{"url" => "http://127.0.0.1:#{@port}/_matrix/push/v1/notify"},
          enabled: false
        }
      ],
      on_conflict: :nothing
    )

    event = %{"event_id" => "$d1", "type" => "m.room.message", "sender" => @sender, "content" => %{"msgtype" => "m.text", "body" => "hi"}}
    Dispatcher.dispatch_event(event, @room)

    Process.sleep(100)
    assert FakePusherGateway.received(@port) == []
  end
end
