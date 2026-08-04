defmodule AxonWeb.SyncFilterTest do
  @moduledoc """
  Regression coverage for classic `/sync`'s room event filter (`filter=`
  query param, `room.timeline`/`room.state` sub-filters) — specifically
  `not_types`, which `AxonWeb.SyncController` didn't read at all before
  this fix (only the allow-list `types` key was ever plucked out of the
  filter, so a `not_types`-only filter was silently a no-op).

  Also covers the behaviour Complement's `TestSyncOmitsStateChangeOnFilteredEvents`
  (https://github.com/element-hq/synapse/issues/16928) exercises: a state
  event that falls inside the timeline "window" (by `limit`) but whose
  *type* the filter excludes from `timeline.events` must still surface in
  `state.events` — i.e. the state/timeline split has to be computed off
  the *unfiltered* event set, with the type filter applied to each half
  independently afterwards, not applied first (which would silently drop
  the state change) or applied to both halves identically (which would
  wrongly exclude it from `state.events` too). See
  `AxonWeb.SyncController.build_incremental_room_data/3` and
  `build_room_data/8`.

  The full Complement scenario forks the room DAG across a federation
  round-trip; that's incidental to what's actually being asserted, so this
  reproduces the essential shape locally with two local, linearly-ordered
  events instead — the "was the split computed before or after the type
  filter" question only depends on relative stream order plus the
  timeline `limit`, not on *how* the events came to be interleaved.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  defp send_state(token, room_id, type, state_key, content) do
    conn =
      authed(token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/#{type}/#{state_key}", content)

    assert conn.status == 200
    decode(conn)["event_id"]
  end

  defp sync(token, since, filter) do
    filter_qs = filter && "&filter=#{URI.encode_www_form(Jason.encode!(filter))}"
    conn = authed(token) |> get("/_matrix/client/v3/sync?since=#{since}&timeout=0#{filter_qs}")
    assert conn.status == 200
    decode(conn)
  end

  defp initial_since(token) do
    conn = authed(token) |> get("/_matrix/client/v3/sync?timeout=0")
    assert conn.status == 200
    decode(conn)["next_batch"]
  end

  test "not_types excludes matching events from the timeline" do
    alice = register("sf_nt_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"name" => "NT"})
    since = initial_since(alice.token)

    send_event(alice.token, room_id, "please_filter_me", %{"body" => "one"})
    send_event(alice.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "two"})

    body =
      sync(alice.token, since, %{
        "room" => %{"timeline" => %{"not_types" => ["please_filter_me"]}}
      })

    timeline_types =
      get_in(body, ["rooms", "join", room_id, "timeline", "events"])
      |> Enum.map(& &1["type"])

    refute "please_filter_me" in timeline_types
    assert "m.room.message" in timeline_types
  end

  test "a state change stays in state.events even when the timeline-limit boundary lands on a filtered-out event" do
    alice = register("sf_sw_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"name" => "Original"})
    since = initial_since(alice.token)

    # S: a state event (room name change) — must survive into `state.events`.
    send_state(alice.token, room_id, "m.room.name", "", %{"name" => "Renamed"})
    # E: a non-state event, sent right after S, of a type the filter excludes.
    send_event(alice.token, room_id, "please_filter_me", %{"body" => "filter me out"})

    body =
      sync(alice.token, since, %{
        "room" => %{"timeline" => %{"not_types" => ["please_filter_me"], "limit" => 1}}
      })

    room = get_in(body, ["rooms", "join", room_id])
    refute is_nil(room), "room missing from sync response"

    state_types = Enum.map(room["state"]["events"], & &1["type"])
    timeline_types = Enum.map(room["timeline"]["events"], & &1["type"])

    assert "m.room.name" in state_types,
           "state change was dropped instead of surfacing in state.events " <>
             "(state=#{inspect(state_types)} timeline=#{inspect(timeline_types)})"

    refute "please_filter_me" in timeline_types,
           "not_types filter did not exclude the event from the timeline"

    refute "please_filter_me" in state_types
  end

  test "senders/not_senders narrow the timeline independently of types" do
    alice = register("sf_snd_a_#{System.unique_integer([:positive])}")
    bob = register("sf_snd_b_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"name" => "Senders", "invite" => [bob.user_id]})

    assert authed(bob.token)
           |> jp("/_matrix/client/v3/join/#{room_id}", %{})
           |> Map.get(:status) == 200

    since = initial_since(alice.token)

    send_event(alice.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "a1"})
    send_event(bob.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "b1"})

    body =
      sync(alice.token, since, %{
        "room" => %{"timeline" => %{"not_senders" => [bob.user_id]}}
      })

    senders =
      get_in(body, ["rooms", "join", room_id, "timeline", "events"])
      |> Enum.map(& &1["sender"])

    assert alice.user_id in senders
    refute bob.user_id in senders
  end
end
