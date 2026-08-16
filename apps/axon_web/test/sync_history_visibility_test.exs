defmodule AxonWeb.SyncHistoryVisibilityTest do
  @moduledoc """
  Regression coverage: `GET /event/{id}` and `/messages` already enforced
  per-event `history_visibility` for a room's current members
  (`AxonWeb.EventController.visibility_bounds/2` + `event_visible?/2`),
  but classic `/sync` (`AxonWeb.SyncController`) and sliding sync
  (`AxonWeb.SlidingSyncController`) did not apply the same gate to their
  timelines — a joined member's `/sync` (initial or newly-joined) or
  sliding sync room entry could include events sent before they joined a
  room whose `history_visibility` is `joined`/`invited`.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  defp join_room(token, room_id) do
    conn = authed(token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    assert conn.status == 200
  end

  defp set_history_visibility(token, room_id, value) do
    conn =
      authed(token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/m.room.history_visibility", %{
        "history_visibility" => value
      })

    assert conn.status == 200
  end

  defp classic_sync_timeline_event_ids(token, room_id) do
    conn = authed(token) |> get("/_matrix/client/v3/sync?timeout=0")
    assert conn.status == 200

    get_in(decode(conn), ["rooms", "join", room_id, "timeline", "events"])
    |> Enum.map(& &1["event_id"])
  end

  defp sliding_sync_timeline_event_ids(token, room_id, timeline_limit \\ 20) do
    conn =
      authed(token)
      |> jp("/_matrix/client/unstable/org.matrix.msc4186/sync", %{
        "lists" => %{
          "a" => %{
            "ranges" => [[0, 9]],
            "required_state" => [],
            "timeline_limit" => timeline_limit
          }
        }
      })

    assert conn.status == 200
    get_in(decode(conn), ["rooms", room_id, "timeline"]) |> Enum.map(& &1["event_id"])
  end

  test "a joined member's initial classic /sync timeline excludes events sent before they joined when visibility is 'joined'" do
    alice = register("shv_cs_a_#{System.unique_integer([:positive])}")
    bob = register("shv_cs_b_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    pre_join_event = send_event(alice.token, room_id, "m.room.message", %{"body" => "before"})
    set_history_visibility(alice.token, room_id, "joined")
    join_room(bob.token, room_id)
    post_join_event = send_event(alice.token, room_id, "m.room.message", %{"body" => "after"})

    event_ids = classic_sync_timeline_event_ids(bob.token, room_id)
    assert post_join_event in event_ids
    refute pre_join_event in event_ids
  end

  test "a joined member's initial classic /sync timeline includes full history when visibility is 'shared' (the default)" do
    alice = register("shv_cs_shared_a_#{System.unique_integer([:positive])}")
    bob = register("shv_cs_shared_b_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    pre_join_event = send_event(alice.token, room_id, "m.room.message", %{"body" => "before"})
    join_room(bob.token, room_id)

    event_ids = classic_sync_timeline_event_ids(bob.token, room_id)
    assert pre_join_event in event_ids
  end

  test "a joined member's sliding sync room timeline excludes events sent before they joined when visibility is 'joined'" do
    alice = register("shv_ss_a_#{System.unique_integer([:positive])}")
    bob = register("shv_ss_b_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    pre_join_event = send_event(alice.token, room_id, "m.room.message", %{"body" => "before"})
    set_history_visibility(alice.token, room_id, "joined")
    join_room(bob.token, room_id)
    post_join_event = send_event(alice.token, room_id, "m.room.message", %{"body" => "after"})

    event_ids = sliding_sync_timeline_event_ids(bob.token, room_id)
    assert post_join_event in event_ids
    refute pre_join_event in event_ids
  end
end
