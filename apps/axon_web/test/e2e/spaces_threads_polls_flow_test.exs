defmodule AxonWeb.E2E.SpacesThreadsPollsFlowTest do
  @moduledoc """
  End-to-end structural/aggregation flow chaining pieces that are each
  unit-tested individually (space hierarchy, thread bundling, reaction
  bundling, poll relation counting) but never exercised together: a space
  with a public child room and a private child room, where the public
  child hosts both a poll and a thread simultaneously, a non-member of the
  space can still walk into the public child's content once they join it
  directly, but the private child is invisible to them in the hierarchy —
  space membership never implies room membership or vice versa.
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

  defp get_event(token, room_id, event_id) do
    conn = authed(token) |> get("/_matrix/client/v3/rooms/#{room_id}/event/#{event_id}")
    assert conn.status == 200
    decode(conn)
  end

  test "space with public+private children; poll and thread coexist in the public child; hierarchy respects room-level access" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    stranger = register("stranger_#{System.unique_integer([:positive])}")

    space_id =
      create_room(alice.token, %{
        "preset" => "public_chat",
        "creation_content" => %{"type" => "m.space"},
        "name" => "Community"
      })

    public_child = create_room(alice.token, %{"preset" => "public_chat", "name" => "General"})

    private_child =
      create_room(alice.token, %{"preset" => "private_chat", "name" => "Secret Council"})

    send_state(alice.token, space_id, "m.space.child", public_child, %{"via" => ["localhost"]})
    send_state(alice.token, space_id, "m.space.child", private_child, %{"via" => ["localhost"]})

    # --- a poll and a thread coexist in the public child, independently bundled ---
    poll_id =
      send_event(alice.token, public_child, "m.poll.start", %{
        "m.text" => [%{"body" => "Best mascot?"}],
        "m.poll" => %{
          "kind" => "m.disclosed",
          "max_selections" => 1,
          "question" => %{"m.text" => [%{"body" => "Best mascot?"}]},
          "answers" => [
            %{"m.id" => "owl", "m.text" => [%{"body" => "Owl"}]},
            %{"m.id" => "fox", "m.text" => [%{"body" => "Fox"}]}
          ]
        }
      })

    send_event(alice.token, public_child, "m.poll.response", %{
      "m.relates_to" => %{"rel_type" => "m.reference", "event_id" => poll_id},
      "m.selections" => ["owl"]
    })

    thread_root_id =
      send_event(alice.token, public_child, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "unrelated discussion root"
      })

    reply_id =
      send_event(alice.token, public_child, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "a reply",
        "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => thread_root_id}
      })

    poll_event = get_event(alice.token, public_child, poll_id)
    assert get_in(poll_event, ["unsigned", "m.relations", "m.reference", "count"]) == 1

    thread_root_event = get_event(alice.token, public_child, thread_root_id)
    thread = get_in(thread_root_event, ["unsigned", "m.relations", "m.thread"])
    assert thread["count"] == 1
    assert thread["latest_event"]["event_id"] == reply_id

    # --- a stranger who is a member of NEITHER the space NOR any child sees nothing in the hierarchy ---
    stranger_hierarchy_conn =
      authed(stranger.token) |> get("/_matrix/client/v1/rooms/#{space_id}/hierarchy")

    assert stranger_hierarchy_conn.status == 200
    stranger_room_ids = decode(stranger_hierarchy_conn)["rooms"] |> Enum.map(& &1["room_id"])
    assert space_id in stranger_room_ids
    assert public_child in stranger_room_ids
    refute private_child in stranger_room_ids

    # --- the stranger joins the public child DIRECTLY (not via the space) ---
    join_conn = authed(stranger.token) |> jp("/_matrix/client/v3/rooms/#{public_child}/join", %{})
    assert join_conn.status == 200

    # Joining the child grants no membership in the space room itself.
    space_members_conn =
      authed(alice.token) |> get("/_matrix/client/v3/rooms/#{space_id}/joined_members")

    refute Map.has_key?(decode(space_members_conn)["joined"], stranger.user_id)

    # Now the stranger can see the poll/thread content directly (real room membership).
    poll_event_for_stranger = get_event(stranger.token, public_child, poll_id)

    assert get_in(poll_event_for_stranger, ["unsigned", "m.relations", "m.reference", "count"]) ==
             1

    relations_conn =
      authed(stranger.token)
      |> get("/_matrix/client/v1/rooms/#{public_child}/relations/#{thread_root_id}/m.thread")

    assert relations_conn.status == 200
    thread_event_ids = decode(relations_conn)["chunk"] |> Enum.map(& &1["event_id"])
    assert reply_id in thread_event_ids

    # But the private child remains inaccessible.
    private_event_conn =
      authed(stranger.token) |> get("/_matrix/client/v3/rooms/#{private_child}/messages")

    assert private_event_conn.status == 403
  end
end
