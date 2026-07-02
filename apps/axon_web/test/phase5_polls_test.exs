defmodule AxonWeb.Phase5PollsTest do
  @moduledoc """
  Phase 5 — Polls (MSC3381, stable). Poll start/response/end are plain
  events already handled by the generic send/state machinery; responses
  and end relate to the start event via m.relates_to{rel_type: m.reference}.
  This covers what Axon adds: the generic relation-count fallback in
  unsigned.m.relations for rel_types without a special aggregation format
  (m.reference here), and that /relations can filter by rel_type/eventType.

  Vote tallying itself is intentionally left to clients (matches how
  Synapse handles polls — no server-side vote counting).
  """

  use AxonWeb.ConnCase, async: false

  defp register(username) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/_matrix/client/v3/register", Jason.encode!(%{
        "username" => username,
        "password" => "Test1234!",
        "kind" => "user",
        "auth" => %{"type" => "m.login.dummy"}
      }))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    %{token: body["access_token"], user_id: body["user_id"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
  defp jp(conn, path, body), do: conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))
  defp jpu(conn, path, body), do: conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token, opts) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", opts)
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp send_event(token, room_id, type, content) do
    txn_id = "txn_#{System.unique_integer([:positive])}"
    conn = authed(token) |> jpu("/_matrix/client/v3/rooms/#{room_id}/send/#{type}/#{txn_id}", content)
    assert conn.status == 200
    decode(conn)["event_id"]
  end

  defp get_event(token, room_id, event_id) do
    conn = authed(token) |> get("/_matrix/client/v3/rooms/#{room_id}/event/#{event_id}")
    assert conn.status == 200
    decode(conn)
  end

  test "poll responses bundle as unsigned.m.relations.m.reference.count, and /relations filters by rel_type" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})
    assert authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{}) |> Map.get(:status) == 200

    poll_id =
      send_event(alice.token, room_id, "m.poll.start", %{
        "m.text" => [%{"body" => "What should we order?"}],
        "m.poll" => %{
          "kind" => "m.disclosed",
          "max_selections" => 1,
          "question" => %{"m.text" => [%{"body" => "What should we order?"}]},
          "answers" => [
            %{"m.id" => "pizza", "m.text" => [%{"body" => "Pizza"}]},
            %{"m.id" => "poutine", "m.text" => [%{"body" => "Poutine"}]}
          ]
        }
      })

    resp1_id =
      send_event(alice.token, room_id, "m.poll.response", %{
        "m.relates_to" => %{"rel_type" => "m.reference", "event_id" => poll_id},
        "m.selections" => ["pizza"]
      })

    send_event(bob.token, room_id, "m.poll.response", %{
      "m.relates_to" => %{"rel_type" => "m.reference", "event_id" => poll_id},
      "m.selections" => ["poutine"]
    })

    poll_event = get_event(alice.token, room_id, poll_id)
    assert get_in(poll_event, ["unsigned", "m.relations", "m.reference", "count"]) == 2

    conn = authed(alice.token) |> get("/_matrix/client/v1/rooms/#{room_id}/relations/#{poll_id}/m.reference/m.poll.response")
    assert conn.status == 200
    body = decode(conn)
    ids = Enum.map(body["chunk"], & &1["event_id"])
    assert resp1_id in ids
    assert length(ids) == 2
  end
end
