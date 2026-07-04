defmodule AxonWeb.TestHelpers do
  @moduledoc """
  Shared HTTP test helpers, consolidating the register/authed/jp/jpu/decode/
  create_room helpers that used to be hand-duplicated (nearly verbatim)
  across ~10 test files. New test files should `import AxonWeb.TestHelpers`
  themselves (not done globally in `AxonWeb.ConnCase`, since Elixir treats a
  local `defp` of the same name/arity as an import as a hard compile error —
  the ~10 existing files' local copies would collide). Existing files keep
  their local copies for now; dedupe them onto this module in a follow-up
  cleanup pass once it's proven out.
  """

  import Plug.Conn
  import Phoenix.ConnTest
  import ExUnit.Assertions

  @endpoint AxonWeb.Endpoint

  @doc "Registers a new user with password auth (m.login.dummy). Returns %{token, device_id, user_id}."
  def register(username, opts \\ %{}) do
    body =
      Map.merge(
        %{
          "username" => username,
          "password" => "Test1234!",
          "kind" => "user",
          "auth" => %{"type" => "m.login.dummy"}
        },
        opts
      )

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/_matrix/client/v3/register", Jason.encode!(body))

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    %{token: resp["access_token"], device_id: resp["device_id"], user_id: resp["user_id"]}
  end

  @doc "Registers a guest account. Returns %{token, device_id, user_id}."
  def register_guest do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/_matrix/client/v3/register", Jason.encode!(%{"kind" => "guest"}))

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    %{token: resp["access_token"], device_id: resp["device_id"], user_id: resp["user_id"]}
  end

  def authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  def jp(conn, path, body),
    do: conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))

  def jpu(conn, path, body),
    do: conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

  def decode(conn), do: Jason.decode!(conn.resp_body)

  @doc "Creates a room as `token`'s user. Returns the room_id."
  def create_room(token, opts \\ %{}) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", opts)
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  @doc "Sends a message-shaped event to a room, returns the event_id."
  def send_event(token, room_id, type, content) do
    txn_id = "txn_#{System.unique_integer([:positive])}"
    conn = authed(token) |> jpu("/_matrix/client/v3/rooms/#{room_id}/send/#{type}/#{txn_id}", content)
    assert conn.status == 200
    decode(conn)["event_id"]
  end
end
