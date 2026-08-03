defmodule AxonPush.NotificationsTest do
  @moduledoc """
  Regression tests for the `notifications` ledger table
  (`AxonPush.Notifications`) and its wiring into `AxonPush.Dispatcher`:
  a matching event records a row for every joined recipient (even one
  with no registered pusher — the ledger must not depend on push setup),
  the sender's own event never records one for themselves, a muted room
  suppresses the row entirely (same push-rule path that suppresses actual
  HTTP push, modeled on `dispatcher_test.exs`'s muting test), and
  `AxonPush.Notifications.list/2` paginates with `only: "highlight"`
  filtering.
  """

  use AxonPush.DataCase, async: false

  alias AxonPush.{Dispatcher, Notifications, UserRules}

  @room "!notifroom:localhost"
  @sender "@notif_alice:localhost"
  @recipient "@notif_bob:localhost"

  setup do
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "users",
      [
        %{
          user_id: @sender,
          localpart: "notif_alice",
          is_guest: false,
          deactivated: false,
          admin: false,
          inserted_at: now,
          updated_at: now
        },
        %{
          user_id: @recipient,
          localpart: "notif_bob",
          is_guest: false,
          deactivated: false,
          admin: false,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    Repo.insert_all(
      "rooms",
      [
        %{
          room_id: @room,
          version: "10",
          creator: @sender,
          is_public: false,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    for u <- [@sender, @recipient] do
      Repo.insert_all(
        "room_memberships",
        [
          %{
            room_id: @room,
            user_id: u,
            membership: "join",
            event_id: "$mem_#{System.unique_integer([:positive])}",
            sender: u,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: {:replace, [:membership]},
        conflict_target: [:room_id, :user_id]
      )
    end

    :ok
  end

  # `Dispatcher.record`/`Notifications.record` looks the dispatched event
  # up by event_id afterward (for stream_ordering/origin_server_ts), so —
  # unlike dispatcher_test.exs, which only ever hand-builds an in-memory
  # event map — this needs a REAL row in `events` first.
  defp insert_event(event_id, sender, content \\ %{"msgtype" => "m.text", "body" => "hello"}) do
    now_ms = System.system_time(:millisecond)
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "events",
      [
        %{
          event_id: event_id,
          room_id: @room,
          sender: sender,
          type: "m.room.message",
          content: content,
          origin_server_ts: now_ms,
          origin: "localhost",
          auth_event_ids: [],
          prev_event_ids: [],
          depth: 1,
          signatures: %{},
          hashes: %{},
          room_version: "10",
          received_at: now
        }
      ]
    )

    %{
      "event_id" => event_id,
      "type" => "m.room.message",
      "sender" => sender,
      "room_id" => @room,
      "content" => content
    }
  end

  defp wait_for_rows(user_id, retries \\ 50) do
    case Notifications.list(user_id) do
      {[], _next} when retries > 0 ->
        Process.sleep(20)
        wait_for_rows(user_id, retries - 1)

      result ->
        result
    end
  end

  test "a matching event records a ledger row for a recipient with no registered pusher" do
    event_id = "$notif_#{System.unique_integer([:positive])}"
    event = insert_event(event_id, @sender)

    Dispatcher.dispatch_event(event, @room)

    {[row], nil} = wait_for_rows(@recipient)
    assert row.event_id == event_id
    assert row.room_id == @room
    assert row.sender == @sender
    assert Enum.any?(row.actions, &(&1 == "notify"))
  end

  test "the sender's own message is never recorded as their own notification" do
    event_id = "$self_#{System.unique_integer([:positive])}"
    event = insert_event(event_id, @sender)

    Dispatcher.dispatch_event(event, @room)

    # Give the async dispatch a beat, then confirm no row ever shows up.
    Process.sleep(150)
    assert Notifications.list(@sender) == {[], nil}
  end

  test "a room-kind push rule muting a room suppresses the ledger row entirely" do
    :ok = UserRules.put_custom_rule(@recipient, "room", @room, %{"actions" => ["dont_notify"]})

    event_id = "$muted_#{System.unique_integer([:positive])}"
    event = insert_event(event_id, @sender)

    Dispatcher.dispatch_event(event, @room)

    Process.sleep(150)
    assert Notifications.list(@recipient) == {[], nil}
  end

  test "a highlighting event is flagged highlight: true and only: \"highlight\" filters to it" do
    plain_id = "$plain_#{System.unique_integer([:positive])}"
    plain_event = insert_event(plain_id, @sender, %{"msgtype" => "m.text", "body" => "plain"})
    Dispatcher.dispatch_event(plain_event, @room)
    {[_], nil} = wait_for_rows(@recipient)

    :ok =
      UserRules.put_custom_rule(@recipient, "override", "hl_rule", %{
        "conditions" => [
          %{"kind" => "event_match", "key" => "content.body", "pattern" => "*urgent*"}
        ],
        "actions" => ["notify", %{"set_tweak" => "highlight", "value" => true}]
      })

    hl_id = "$hl_#{System.unique_integer([:positive])}"
    hl_event = insert_event(hl_id, @sender, %{"msgtype" => "m.text", "body" => "this is urgent"})
    Dispatcher.dispatch_event(hl_event, @room)

    {rows, _next} =
      wait_until(fn ->
        {r, n} = Notifications.list(@recipient)
        if length(r) >= 2, do: {r, n}, else: {[], nil}
      end)

    assert length(rows) == 2
    assert Enum.any?(rows, &(&1.event_id == hl_id and &1.highlight == true))
    assert Enum.any?(rows, &(&1.event_id == plain_id and &1.highlight == false))

    {only_highlights, _} = Notifications.list(@recipient, only: "highlight")
    assert [%{event_id: ^hl_id, highlight: true}] = only_highlights
  end

  test "list/2 paginates with from/limit" do
    ids =
      for i <- 1..5 do
        id = "$page#{i}_#{System.unique_integer([:positive])}"
        event = insert_event(id, @sender, %{"msgtype" => "m.text", "body" => "msg #{i}"})
        Dispatcher.dispatch_event(event, @room)
        id
      end

    {rows, _next} =
      wait_until(fn ->
        r = Notifications.list(@recipient)
        if elem(r, 0) |> length() >= 5, do: r, else: {[], nil}
      end)

    assert length(rows) == 5

    {page1, next_token} = Notifications.list(@recipient, limit: 2)
    assert length(page1) == 2
    assert next_token != nil

    {page2, _next2} = Notifications.list(@recipient, limit: 2, from: next_token)
    assert length(page2) == 2

    # Newest-first, no overlap between pages.
    page1_ids = Enum.map(page1, & &1.event_id)
    page2_ids = Enum.map(page2, & &1.event_id)
    assert page1_ids -- ids == []
    assert page2_ids -- ids == []
    assert MapSet.disjoint?(MapSet.new(page1_ids), MapSet.new(page2_ids))
  end

  defp wait_until(fun, retries \\ 50) do
    case fun.() do
      {[], nil} when retries > 0 ->
        Process.sleep(20)
        wait_until(fun, retries - 1)

      result ->
        result
    end
  end
end
