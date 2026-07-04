defmodule AxonWeb.MediaControllerTest do
  @moduledoc """
  Covers the gaps `phase4_test.exs` doesn't: the `url_preview` stub and
  download-of-unknown-media. Upload/download/thumbnail happy paths are
  already covered there.
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
    %{token: body["access_token"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "url_preview is a documented-not-implemented 404 stub, not a silent success" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/media/preview_url?url=https://example.com")
    assert conn.status == 404
    assert decode(conn)["errcode"] == "M_NOT_FOUND"
  end

  test "downloading an unknown local media_id 404s" do
    conn = build_conn() |> get("/_matrix/media/v3/download/localhost/nonexistent_media_id")
    assert conn.status == 404
  end

  test "thumbnailing an unknown local media_id 404s" do
    conn = build_conn() |> get("/_matrix/media/v3/thumbnail/localhost/nonexistent_media_id?width=32&height=32")
    assert conn.status == 404
  end
end
