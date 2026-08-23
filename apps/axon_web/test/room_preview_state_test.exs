defmodule AxonWeb.RoomPreviewStateTest do
  @moduledoc """
  Regression coverage for MSC4311 ("Full create event in invite/knock
  stripped state"): a room preview handed to a user who hasn't joined
  (`invite_state`/`knock_state`) must include the room's `m.room.create`
  event *in full* (all PDU fields — `event_id`, `origin_server_ts`,
  `hashes`, `signatures`, ...), not the ordinary
  type/state_key/sender/content-only stripped shape every other preview
  state event type gets. Complement's TestMSC4311FullCreateEventOnStrippedState
  asserts this by checking `origin_server_ts` is present on the create
  event within `invite_state.events`.

  Covers `AxonWeb.SyncHelpers.preview_state_events/1` (the shared helper)
  via its three call sites:
    - a same-server invite's `invite_state` (classic `/sync`, via
      `build_invite_state/2`)
    - a same-server knock's `knock_state`
    - the outbound `invite_room_state` this server hands a *remote*
      invitee over federation (`AxonWeb.RoomController`'s
      `federate_invite/4`) — the receiving side has no independent logic
      of its own here, it just stores and replays whatever it's sent (see
      `preview_state_events/1`'s doc), so getting this outbound payload
      right is what makes the federated round trip correct too; this is
      the "remote" half of the Complement test, which needs a second real
      homeserver to observe end-to-end and so isn't otherwise exercised
      by axon's own suite.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}

  @port 19_211
  @server_name "fake-msc4311.test"

  defp create_event_of(events) do
    Enum.find(events, &(&1["type"] == "m.room.create"))
  end

  defp other_event_of(events) do
    Enum.find(events, &(&1["type"] == "m.room.join_rules"))
  end

  test "a same-server invite's invite_state carries the full create event" do
    alice = register("msc4311_local_a_#{System.unique_integer([:positive])}")
    bob = register("msc4311_local_b_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"name" => "MSC4311 local", "invite" => [bob.user_id]})

    conn = authed(bob.token) |> get("/_matrix/client/v3/sync?timeout=0")
    assert conn.status == 200
    body = decode(conn)

    events = get_in(body, ["rooms", "invite", room_id, "invite_state", "events"])
    refute is_nil(events), "no invite_state for #{room_id}"

    create_event = create_event_of(events)
    refute is_nil(create_event), "m.room.create missing from invite_state"

    assert Map.has_key?(create_event, "origin_server_ts"),
           "m.room.create in invite_state was stripped instead of sent in full"

    assert Map.has_key?(create_event, "event_id")

    # Every other preview-state event type keeps the ordinary stripped
    # shape — only create gets the MSC4311 treatment.
    other_event = other_event_of(events)
    refute is_nil(other_event)
    refute Map.has_key?(other_event, "origin_server_ts")
  end

  test "a same-server knock's knock_state carries the full create event" do
    alice = register("msc4311_knock_a_#{System.unique_integer([:positive])}")

    knocker = register("msc4311_knock_b_#{System.unique_integer([:positive])}")

    room_id =
      create_room(alice.token, %{
        "name" => "MSC4311 knock",
        "preset" => "public_chat",
        "room_version" => "7",
        "initial_state" => [
          %{"type" => "m.room.join_rules", "state_key" => "", "content" => %{"join_rule" => "knock"}}
        ]
      })

    knock_conn =
      authed(knocker.token)
      |> jp("/_matrix/client/v3/knock/#{room_id}", %{})

    assert knock_conn.status == 200

    conn = authed(knocker.token) |> get("/_matrix/client/v3/sync?timeout=0")
    assert conn.status == 200
    body = decode(conn)

    events = get_in(body, ["rooms", "knock", room_id, "knock_state", "events"])
    refute is_nil(events), "no knock_state for #{room_id}"

    create_event = create_event_of(events)
    refute is_nil(create_event), "m.room.create missing from knock_state"

    assert Map.has_key?(create_event, "origin_server_ts"),
           "m.room.create in knock_state was stripped instead of sent in full"
  end

  describe "federated invite (outbound invite_room_state)" do
    setup do
      start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
      KeyCache.clear()

      Application.put_env(:axon_federation, :server_overrides, %{
        @server_name => "http://127.0.0.1:#{@port}"
      })

      on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
      :ok
    end

    test "invite_room_state sent to a remote invitee includes the full m.room.create event" do
      alice = register("msc4311_fed_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"name" => "MSC4311 federated"})

      target_user_id = "@remote-target:#{@server_name}"

      # This response only needs to be well-shaped enough that axon's
      # post-response handling (persisting the now-double-signed event)
      # doesn't matter for this test — only the *outbound request* is
      # under test.
      FakeRemoteMatrixServer.put_response(
        @port,
        {"PUT", ~r{^/_matrix/federation/v2/invite/}},
        200,
        %{
          "event" => %{
            "type" => "m.room.member",
            "room_id" => room_id,
            "sender" => alice.user_id,
            "state_key" => target_user_id,
            "content" => %{"membership" => "invite"},
            "event_id" => "$msc4311fakeevent",
            "origin_server_ts" => 0
          }
        }
      )

      _conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", %{"user_id" => target_user_id})

      requests =
        FakeRemoteMatrixServer.requests(@port)
        |> Enum.filter(&(&1.method == "PUT" and &1.path =~ ~r{^/_matrix/federation/v2/invite/}))

      assert [request] = requests
      invite_room_state = request.body["invite_room_state"]
      assert is_list(invite_room_state)

      create_event = create_event_of(invite_room_state)
      refute is_nil(create_event), "m.room.create missing from invite_room_state"

      assert Map.has_key?(create_event, "origin_server_ts"),
             "m.room.create in invite_room_state was stripped instead of sent in full"

      other_event = other_event_of(invite_room_state)
      refute is_nil(other_event)
      refute Map.has_key?(other_event, "origin_server_ts")
    end
  end
end
