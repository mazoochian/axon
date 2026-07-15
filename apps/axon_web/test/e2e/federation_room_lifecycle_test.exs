defmodule AxonWeb.E2E.FederationRoomLifecycleTest do
  @moduledoc """
  End-to-end federation room lifecycle against a real signed counterparty
  (`AxonFederation.FakeRemoteMatrixServer`), chaining pieces that are each
  unit-tested individually elsewhere but never exercised together in one
  flow: local room creation -> remote join (make_join/send_join) -> local
  message fans out to the remote member (FederationFanout) -> remote
  message arrives inbound (send_transaction) -> remote member leaves
  (make_leave/send_leave).
  """

  use AxonWeb.ConnCase, async: false

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}
  alias AxonCore.EventStore
  alias AxonRoom.{CreateRoom, RoomProcess}

  @port 19_000
  @server_name "fake-e2e-fed.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
    :ok
  end

  defp new_local_user(prefix) do
    localpart = "#{prefix}_#{System.unique_integer([:positive])}"

    {:ok, %{user_id: user_id}} =
      AxonCore.UserStore.register(localpart, "Test1234!", server_name: "localhost")

    user_id
  end

  defp remote_user(prefix), do: "@#{prefix}_#{System.unique_integer([:positive])}:#{@server_name}"

  defp signed_remote_event(fields) do
    FakeRemoteMatrixServer.sign_event(@port, Map.merge(%{"hashes" => %{"sha256" => "x"}}, fields))
  end

  defp signed_get(path) do
    header = FakeRemoteMatrixServer.sign_request(@port, "GET", path)
    build_conn() |> put_req_header("authorization", header) |> get(path)
  end

  defp signed_put(path, body) do
    header = FakeRemoteMatrixServer.sign_request(@port, "PUT", path, body)

    build_conn()
    |> put_req_header("authorization", header)
    |> put_req_header("content-type", "application/json")
    |> put(path, Jason.encode!(body))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp wait_until(fun, retries \\ 50) do
    case fun.() do
      nil when retries > 0 ->
        Process.sleep(20)
        wait_until(fun, retries - 1)

      false when retries > 0 ->
        Process.sleep(20)
        wait_until(fun, retries - 1)

      result ->
        result
    end
  end

  test "full lifecycle: remote joins, messages flow both directions, remote leaves" do
    owner = new_local_user("owner")

    {:ok, room_id} =
      CreateRoom.execute(owner,
        server_name: "localhost",
        preset: "public_chat",
        name: "Federated Room"
      )

    remote_member = remote_user("member")

    # --- Remote joins via make_join/send_join ---
    make_join_conn =
      signed_get(
        "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(remote_member)}"
      )

    assert make_join_conn.status == 200
    template = decode(make_join_conn)["event"]

    join_event =
      signed_remote_event(
        Map.merge(template, %{
          "event_id" => "$join_#{System.unique_integer([:positive])}",
          "origin_server_ts" => System.os_time(:millisecond)
        })
      )

    send_join_conn =
      signed_put(
        "/_matrix/federation/v2/send_join/#{URI.encode(room_id)}/#{URI.encode(join_event["event_id"])}",
        join_event
      )

    assert send_join_conn.status == 200
    assert EventStore.get_membership(room_id, remote_member) == {:ok, "join"}

    # --- A local message fans out to the now-remote member via FederationFanout ---
    {:ok, local_event_id} =
      RoomProcess.send_event(room_id, owner, "m.room.message", %{"body" => "hello from axon"})

    fanned_out =
      wait_until(fn ->
        FakeRemoteMatrixServer.requests(@port)
        |> Enum.find(fn r ->
          r.method == "PUT" and String.contains?(r.path, "/_matrix/federation/v1/send/") and
            match?(%{"pdus" => [%{"event_id" => ^local_event_id}]}, r.body)
        end)
      end)

    refute is_nil(fanned_out), "expected the local message to be fanned out to #{@server_name}"

    # And the outbound PDU is validly signed as axon's own server identity —
    # a real remote server could verify it independently of anything this test controls.
    axon_key_conn = build_conn() |> get("/_matrix/key/v2/server")
    axon_key_doc = decode(axon_key_conn)
    [{key_id, %{"key" => key_b64}}] = Map.to_list(axon_key_doc["verify_keys"])
    pub_key = Base.decode64!(key_b64, padding: false)
    [sent_pdu] = fanned_out.body["pdus"]
    assert AxonCrypto.EventHash.verify_signature(sent_pdu, "localhost", key_id, pub_key) == :ok

    # --- An inbound message from the remote member arrives via send_transaction ---
    {last_event_id, depth} = RoomProcess.get_position(room_id)

    inbound_pdu =
      signed_remote_event(%{
        "event_id" => "$inbound_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => remote_member,
        "content" => %{"body" => "hello from the remote side"},
        "depth" => depth + 1,
        "prev_events" => [last_event_id],
        "origin_server_ts" => System.os_time(:millisecond)
      })

    txn_id = "txn_#{System.unique_integer([:positive])}"
    txn_conn = signed_put("/_matrix/federation/v1/send/#{txn_id}", %{"pdus" => [inbound_pdu]})
    assert txn_conn.status == 200

    {new_last_event_id, _} = RoomProcess.get_position(room_id)
    assert new_last_event_id == inbound_pdu["event_id"]

    # --- The remote member leaves via make_leave/send_leave ---
    make_leave_conn =
      signed_get(
        "/_matrix/federation/v1/make_leave/#{URI.encode(room_id)}/#{URI.encode(remote_member)}"
      )

    assert make_leave_conn.status == 200
    leave_template = decode(make_leave_conn)["event"]

    leave_event =
      signed_remote_event(
        Map.merge(leave_template, %{
          "event_id" => "$leave_#{System.unique_integer([:positive])}",
          "origin_server_ts" => System.os_time(:millisecond)
        })
      )

    send_leave_conn =
      signed_put(
        "/_matrix/federation/v2/send_leave/#{URI.encode(room_id)}/#{URI.encode(leave_event["event_id"])}",
        leave_event
      )

    assert send_leave_conn.status == 200
    assert EventStore.get_membership(room_id, remote_member) == {:ok, "leave"}
  end
end
