defmodule AxonWeb.ReportControllerTest do
  @moduledoc "Tests content reporting (event and whole-room reports)."

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AxonCore.Repo

  defp register(username) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/register",
        Jason.encode!(%{
          "username" => username,
          "password" => "Test1234!",
          "kind" => "user",
          "auth" => %{"type" => "m.login.dummy"}
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    %{token: body["access_token"], user_id: body["user_id"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp jp(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", %{})
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp send_message(token, room_id) do
    txn = "txn_#{System.unique_integer([:positive])}"

    conn =
      authed(token)
      |> put_req_header("content-type", "application/json")
      |> put(
        "/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn}",
        Jason.encode!(%{"body" => "offensive content"})
      )

    assert conn.status == 200
    decode(conn)["event_id"]
  end

  test "report_event persists a row with reason and score" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id = send_message(alice.token, room_id)

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/report/#{event_id}", %{
        "reason" => "spam",
        "score" => -100
      })

    assert conn.status == 200

    row =
      Repo.one(
        from(r in "reports",
          where: r.room_id == ^room_id and r.event_id == ^event_id,
          select: %{reason: r.reason, score: r.score, reporter_id: r.reporter_id}
        )
      )

    assert row.reason == "spam"
    assert row.score == -100
    assert row.reporter_id == alice.user_id
  end

  test "report_room persists a whole-room report with a nil event_id" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/report", %{"reason" => "abusive room"})

    assert conn.status == 200

    row =
      Repo.one(
        from(r in "reports",
          where: r.room_id == ^room_id and is_nil(r.event_id),
          select: r.reason
        )
      )

    assert row == "abusive room"
  end

  test "duplicate reports of the same event both persist (no dedup)" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id = send_message(alice.token, room_id)

    authed(alice.token)
    |> jp("/_matrix/client/v3/rooms/#{room_id}/report/#{event_id}", %{"reason" => "first"})

    authed(alice.token)
    |> jp("/_matrix/client/v3/rooms/#{room_id}/report/#{event_id}", %{"reason" => "second"})

    count =
      Repo.aggregate(
        from(r in "reports", where: r.room_id == ^room_id and r.event_id == ^event_id),
        :count
      )

    assert count == 2
  end

  test "a report with no reason/score still succeeds" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id = send_message(alice.token, room_id)

    conn =
      authed(alice.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/report/#{event_id}", %{})

    assert conn.status == 200
  end
end
