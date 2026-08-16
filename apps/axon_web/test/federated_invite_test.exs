defmodule AxonWeb.FederatedInviteTest do
  @moduledoc """
  Outbound federated invite: `POST /rooms/:id/invite` for a user on another
  homeserver.

  Regression for a 500 Complement hit during `TestKnocking`'s setup (before
  any knocking happened). Room versions 3+ carry no `event_id` on the wire —
  it is the event's own reference hash — so the countersigned event a remote
  hands back has no `event_id` field, even though the one we sent it did.
  Inserting that as-is violated the events table's NOT NULL `event_id` and the
  resulting changeset error fell through `FallbackController`'s catch-all as
  an opaque `500 M_UNKNOWN`, on the *inviter's* own request.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}

  @port 19_640
  @server_name "fake-fedinvite.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
    :ok
  end

  # AxonFederation.OutboundQueue delivers asynchronously (a spawned Task,
  # not inline with enqueue/2) — a relay assertion checked synchronously
  # right after the triggering HTTP call is a race, not a real check.
  defp wait_until(deadline_ms, fun) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("condition not met before deadline")
      else
        Process.sleep(20)
        wait_until(deadline_ms, fun)
      end
    end
  end

  # Mirrors Complement's federation.HandleInviteRequests and any real
  # homeserver: countersign the event we were given and hand it straight back
  # — crucially *without* re-adding an event_id, which the wire format for
  # room v3+ does not carry.
  defp countersign_without_event_id do
    FakeRemoteMatrixServer.put_response(
      @port,
      {"PUT", ~r{/_matrix/federation/v2/invite/}},
      200,
      fn body ->
        signed =
          body["event"]
          |> Map.delete("event_id")
          |> then(&FakeRemoteMatrixServer.sign_event(@port, &1))
          |> Map.delete("event_id")

        %{"event" => signed}
      end
    )
  end

  defp invite(token, room_id, target) do
    authed(token) |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", %{"user_id" => target})
  end

  for version <- ["7", "11"] do
    test "a remote invite succeeds in room version #{version} when the countersigned event omits event_id" do
      alice = register("fedinv_#{System.unique_integer([:positive])}")

      room_id =
        create_room(alice.token, %{
          "preset" => "private_chat",
          "room_version" => unquote(version)
        })

      david = "@david_#{System.unique_integer([:positive])}:#{@server_name}"
      countersign_without_event_id()

      conn = invite(alice.token, room_id, david)

      assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"

      # The invite really landed: the remote user is now an invited member.
      assert AxonCore.EventStore.get_membership(room_id, david) == {:ok, "invite"}
    end
  end

  # Regression: a cross-server invite's final signed event was applied via
  # RoomProcess.apply_remote_event/2 with no relay_exclude, so it only ever
  # reached this server's own DB/sync — never any *other* server already
  # resident in the room. Same shape as the send_join/leave/knock relay gap
  # (RoomProcess.apply_remote_event/3's moduledoc): our server is the only
  # party that can tell a room's other resident servers about a brand-new
  # invite, since they were never part of this make/send-style round trip
  # with the invitee's server. Complement: TestFederationRejectInvite (the
  # first of its two waits — Delia's server never sees Charlie's invite).
  test "a remote invite is relayed to the room's other resident server, not just applied locally" do
    bob_port = 19_641
    bob_server = "fake-fedinvite-bob.test"
    start_supervised!({FakeRemoteMatrixServer, port: bob_port, server_name: bob_server})

    Application.put_env(
      :axon_federation,
      :server_overrides,
      Map.put(
        Application.get_env(:axon_federation, :server_overrides, %{}),
        bob_server,
        "http://127.0.0.1:#{bob_port}"
      )
    )

    alice = register("fedinv_relay_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    # Bob (a different remote server) is already a resident member.
    bob = "@bob_#{System.unique_integer([:positive])}:#{bob_server}"
    {last_event_id, depth} = AxonRoom.RoomProcess.get_position(room_id)

    bob_join_pdu = %{
      "event_id" => "$bobjoin_#{System.unique_integer([:positive])}",
      "room_id" => room_id,
      "type" => "m.room.member",
      "state_key" => bob,
      "sender" => bob,
      "content" => %{"membership" => "join"},
      "depth" => depth + 1,
      "prev_events" => [last_event_id],
      "auth_events" => [],
      "origin" => bob_server,
      "origin_server_ts" => System.os_time(:millisecond)
    }

    {:ok, _} = AxonRoom.RoomProcess.apply_remote_event(room_id, bob_join_pdu)

    # Charlie's own server countersigns and hands the invite back, same as
    # the ordinary invite tests above.
    david = "@david_relay_#{System.unique_integer([:positive])}:#{@server_name}"
    countersign_without_event_id()

    conn = invite(alice.token, room_id, david)
    assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"

    assert AxonCore.EventStore.get_membership(room_id, david) == {:ok, "invite"}

    # Bob's server must have received a /send transaction carrying david's
    # invite via relay — not just applied locally on our own side.
    # Delivery is async (AxonFederation.OutboundQueue spawns a Task), so
    # poll rather than asserting synchronously.
    wait_until(System.monotonic_time(:millisecond) + 5_000, fn ->
      Enum.any?(FakeRemoteMatrixServer.requests(bob_port), fn req ->
        req.method == "PUT" and req.path =~ "/_matrix/federation/v1/send/" and
          Enum.any?(req.body["pdus"] || [], fn pdu ->
            pdu["type"] == "m.room.member" and pdu["state_key"] == david and
              get_in(pdu, ["content", "membership"]) == "invite"
          end)
      end)
    end)
  end

  # Regression: AxonRoom.CreateRoom.execute/2's own invite list (the
  # `invite` param of POST /createRoom itself, not the separate
  # POST /rooms/:id/invite endpoint exercised by every other test in this
  # file) sent every invitee — remote ones included — through
  # RoomProcess.send_event/5 directly, which only ever writes local state
  # and only fans a PDU out to servers of already-*joined* members. A
  # brand-new remote invitee's own server never received anything at all:
  # no v2/invite handshake, no PDU, nothing. Complement:
  # TestDeviceListsUpdateOverFederation and TestToDeviceMessagesOverFederation
  # both depend on a room+invite created this way and hung forever on the
  # invitee's own MustSyncUntil(SyncInvitedTo).
  test "createRoom's own invite list federates a remote invitee too" do
    alice = register("fedinv_create_#{System.unique_integer([:positive])}")
    david = "@david_#{System.unique_integer([:positive])}:#{@server_name}"
    countersign_without_event_id()

    room_id =
      create_room(alice.token, %{
        "preset" => "private_chat",
        "invite" => [david]
      })

    # The invite really landed on our own side too.
    assert AxonCore.EventStore.get_membership(room_id, david) == {:ok, "invite"}

    # And the remote server actually received the v2/invite handshake —
    # not just a locally-applied event nobody else ever heard about.
    wait_until(System.monotonic_time(:millisecond) + 5_000, fn ->
      Enum.any?(FakeRemoteMatrixServer.requests(@port), fn req ->
        req.method == "PUT" and req.path =~ ~r{/_matrix/federation/v2/invite/} and
          get_in(req.body, ["event", "state_key"]) == david
      end)
    end)
  end

  test "a remote server that fails the invite still yields a clean 502, not a 500" do
    alice = register("fedinv_fail_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})
    david = "@david_#{System.unique_integer([:positive])}:#{@server_name}"

    FakeRemoteMatrixServer.put_response(
      @port,
      {"PUT", ~r{/_matrix/federation/v2/invite/}},
      403,
      %{"errcode" => "M_FORBIDDEN", "error" => "nope"}
    )

    conn = invite(alice.token, room_id, david)

    assert conn.status == 502
    assert %{"errcode" => "M_UNKNOWN"} = Jason.decode!(conn.resp_body)
  end
end
