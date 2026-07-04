defmodule AxonWeb.ReceiptControllerTest do
  @moduledoc "Tests read receipts and read markers."

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AxonCore.Repo

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
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", %{})
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp send_message(token, room_id) do
    txn = "txn_#{System.unique_integer([:positive])}"
    conn = authed(token) |> put_req_header("content-type", "application/json") |> put("/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn}", Jason.encode!(%{"body" => "hi"}))
    assert conn.status == 200
    decode(conn)["event_id"]
  end

  test "posting a receipt persists it" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id = send_message(alice.token, room_id)

    conn = authed(alice.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read/#{event_id}", %{})
    assert conn.status == 200

    row = Repo.one(from(r in "receipts", where: r.room_id == ^room_id and r.user_id == ^alice.user_id and r.receipt_type == "m.read", select: r.event_id))
    assert row == event_id
  end

  test "a later receipt for the same type replaces the earlier one" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id1 = send_message(alice.token, room_id)
    event_id2 = send_message(alice.token, room_id)

    authed(alice.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read/#{event_id1}", %{})
    authed(alice.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read/#{event_id2}", %{})

    row = Repo.one(from(r in "receipts", where: r.room_id == ^room_id and r.user_id == ^alice.user_id and r.receipt_type == "m.read", select: r.event_id))
    assert row == event_id2
  end

  test "read_markers sets m.read, m.read.private, and m.fully_read independently" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id = send_message(alice.token, room_id)

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/read_markers", %{
        "m.read" => event_id,
        "m.read.private" => event_id,
        "m.fully_read" => event_id
      })

    assert conn.status == 200

    read_row = Repo.one(from(r in "receipts", where: r.room_id == ^room_id and r.receipt_type == "m.read", select: r.event_id))
    assert read_row == event_id

    private_row = Repo.one(from(r in "receipts", where: r.room_id == ^room_id and r.receipt_type == "m.read.private", select: r.event_id))
    assert private_row == event_id

    fully_read = Repo.one(from(a in "room_account_data", where: a.room_id == ^room_id and a.type == "m.fully_read", select: a.content))
    assert fully_read["event_id"] == event_id
  end

  test "read_markers with only m.read set doesn't touch the others" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token)
    event_id = send_message(alice.token, room_id)

    conn = authed(alice.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/read_markers", %{"m.read" => event_id})
    assert conn.status == 200

    fully_read = Repo.one(from(a in "room_account_data", where: a.room_id == ^room_id and a.type == "m.fully_read", select: a.content))
    assert fully_read == nil
  end
end
