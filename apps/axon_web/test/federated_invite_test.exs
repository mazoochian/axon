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
