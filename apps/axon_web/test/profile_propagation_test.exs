defmodule AxonWeb.ProfilePropagationTest do
  @moduledoc """
  Regression test: profile changes (displayname/avatar) propagate to joined
  rooms via an m.room.member state event that keeps membership == "join".
  Clients tell a real join apart from a profile-only update by diffing
  content against unsigned.prev_content (MSC3442) — so that field must be
  present and must carry the *previous* profile, not the new one.
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

  defp authed(token) do
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end

  defp jp(conn, path, body) do
    conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))
  end

  defp jpu(conn, path, body) do
    conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", %{})
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp sync(token, since \\ nil) do
    path = if since, do: "/_matrix/client/v3/sync?since=#{since}&timeout=0", else: "/_matrix/client/v3/sync?timeout=0"
    conn = authed(token) |> get(path)
    assert conn.status == 200
    decode(conn)
  end

  defp member_events(sync_body, room_id) do
    timeline = get_in(sync_body, ["rooms", "join", room_id, "timeline", "events"]) || []
    state = get_in(sync_body, ["rooms", "join", room_id, "state", "events"]) || []

    (timeline ++ state)
    |> Enum.filter(&(&1["type"] == "m.room.member" and &1["content"]["displayname"] == "Alice B."))
  end

  test "displayname change keeps membership=join and sets unsigned.prev_content" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)

    # Baseline sync so the initial join event is consumed.
    initial = sync(alice.token)
    since = initial["next_batch"]

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/profile/#{alice.user_id}/displayname", %{"displayname" => "Alice B."})

    assert conn.status == 200

    # Profile propagation runs via Task.start/1 (fire-and-forget); poll sync
    # briefly until the member event shows up.
    body =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        body = sync(alice.token, since)
        case member_events(body, room_id) do
          [] ->
            Process.sleep(50)
            {:cont, body}

          _ ->
            {:halt, body}
        end
      end)

    [event] = member_events(body, room_id)

    assert event["content"]["membership"] == "join"
    assert event["content"]["displayname"] == "Alice B."

    prev_content = event["unsigned"]["prev_content"]
    refute is_nil(prev_content)
    assert prev_content["membership"] == "join"
    refute prev_content["displayname"] == "Alice B."
  end
end
