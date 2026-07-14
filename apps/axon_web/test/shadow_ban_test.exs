defmodule AxonWeb.ShadowBanTest do
  @moduledoc """
  Regression tests for Phase 13's shadow-ban enforcement: a shadow-banned
  user's own non-state (message-like) events must be invisible to every
  *other* local viewer's `/sync` (both classic and sliding), but always
  visible to the shadow-banned user's own `/sync` — and must not be
  federated out. State events (e.g. joins) stay visible to everyone
  regardless, since hiding those would corrupt other viewers' picture of
  room membership.
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import AxonWeb.TestHelpers

  alias AxonCore.Repo
  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}

  @port 19_300
  @server_name "fake-shadowban.test"

  defp shadow_ban(user_id) do
    Repo.update_all(from(u in "users", where: u.user_id == ^user_id), set: [shadow_banned: true])
  end

  defp sync_events(token, since \\ nil) do
    path = if since, do: "/_matrix/client/v3/sync?since=#{since}", else: "/_matrix/client/v3/sync"
    conn = authed(token) |> get(path)
    assert conn.status == 200
    decode(conn)
  end

  test "a shadow-banned user's message is invisible to other members but visible to themself" do
    alice = register("sb_alice_#{System.unique_integer([:positive])}")
    bob = register("sb_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    assert authed(bob.token)
           |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
           |> Map.get(:status) == 200

    shadow_ban(bob.user_id)

    alice_since = sync_events(alice.token)["next_batch"]
    bob_since = sync_events(bob.token)["next_batch"]

    event_id =
      send_event(bob.token, room_id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "buy my spam"
      })

    assert is_binary(event_id)

    # Bob (the shadow-banned sender) sees his own message normally.
    bob_body = sync_events(bob.token, bob_since)
    bob_events = get_in(bob_body, ["rooms", "join", room_id, "timeline", "events"]) || []
    assert Enum.any?(bob_events, &(&1["event_id"] == event_id))

    # Alice does not.
    alice_body = sync_events(alice.token, alice_since)
    alice_events = get_in(alice_body, ["rooms", "join", room_id, "timeline", "events"]) || []
    refute Enum.any?(alice_events, &(&1["event_id"] == event_id))
  end

  test "shadow-ban does not hide state events like joins" do
    alice = register("sb_state_alice_#{System.unique_integer([:positive])}")
    bob = register("sb_state_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    shadow_ban(bob.user_id)

    alice_since = sync_events(alice.token)["next_batch"]

    assert authed(bob.token)
           |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
           |> Map.get(:status) == 200

    alice_body = sync_events(alice.token, alice_since)

    state_and_timeline =
      (get_in(alice_body, ["rooms", "join", room_id, "state", "events"]) || []) ++
        (get_in(alice_body, ["rooms", "join", room_id, "timeline", "events"]) || [])

    assert Enum.any?(
             state_and_timeline,
             &(&1["type"] == "m.room.member" and &1["state_key"] == bob.user_id and
                 &1["content"]["membership"] == "join")
           )
  end

  describe "federation skip" do
    setup do
      start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
      KeyCache.clear()

      Application.put_env(:axon_federation, :server_overrides, %{
        @server_name => "http://127.0.0.1:#{@port}"
      })

      on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
      :ok
    end

    test "a shadow-banned user's message is never sent to remote servers in the room" do
      alice = register("sb_fed_alice_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"preset" => "public_chat"})
      shadow_ban(alice.user_id)

      remote_member = "@remote:#{@server_name}"

      pdu =
        FakeRemoteMatrixServer.sign_event(@port, %{
          "event_id" => "$sb_seed_#{System.unique_integer([:positive])}",
          "room_id" => room_id,
          "type" => "m.room.member",
          "state_key" => remote_member,
          "sender" => remote_member,
          "content" => %{"membership" => "join"},
          "depth" => 5,
          "prev_events" => [],
          "origin_server_ts" => System.os_time(:millisecond),
          "hashes" => %{"sha256" => "x"}
        })

      {:ok, _} = AxonRoom.RoomProcess.apply_remote_event(room_id, pdu)

      event_id =
        send_event(alice.token, room_id, "m.room.message", %{
          "msgtype" => "m.text",
          "body" => "shadowbanned spam"
        })

      Process.sleep(300)

      sent_bodies =
        FakeRemoteMatrixServer.requests(@port)
        |> Enum.filter(&String.starts_with?(&1.path, "/_matrix/federation/v1/send/"))
        |> Enum.flat_map(&(&1.body["pdus"] || []))

      refute Enum.any?(sent_bodies, &(&1["event_id"] == event_id))
    end
  end
end
