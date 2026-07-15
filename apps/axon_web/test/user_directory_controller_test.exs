defmodule AxonWeb.UserDirectoryControllerTest do
  @moduledoc "Tests user directory search."

  use AxonWeb.ConnCase, async: false

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

  defp jpu(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp search(token, term),
    do: authed(token) |> jp("/_matrix/client/v3/user_directory/search", %{"search_term" => term})

  test "finds a user by localpart substring" do
    unique = "zorbleflug#{System.unique_integer([:positive])}"
    target = register(unique)
    searcher = register("searcher_#{System.unique_integer([:positive])}")

    conn = search(searcher.token, unique)
    assert conn.status == 200
    assert Enum.any?(decode(conn)["results"], &(&1["user_id"] == target.user_id))
  end

  test "finds a user by display name substring" do
    target = register("displaytest_#{System.unique_integer([:positive])}")
    unique_name = "Quazzlefrob #{System.unique_integer([:positive])}"

    authed(target.token)
    |> jpu("/_matrix/client/v3/profile/#{target.user_id}/displayname", %{
      "displayname" => unique_name
    })

    searcher = register("searcher2_#{System.unique_integer([:positive])}")
    conn = search(searcher.token, unique_name)
    assert Enum.any?(decode(conn)["results"], &(&1["user_id"] == target.user_id))
  end

  test "an empty search term returns no results" do
    searcher = register("searcher3_#{System.unique_integer([:positive])}")
    conn = search(searcher.token, "")
    assert decode(conn)["results"] == []
  end

  test "a deactivated user is excluded from results" do
    unique = "deactivatedsearch#{System.unique_integer([:positive])}"
    target = register(unique)

    authed(target.token)
    |> jp("/_matrix/client/v3/account/deactivate", %{
      "auth" => %{
        "type" => "m.login.password",
        "identifier" => %{"user" => target.user_id},
        "password" => "Test1234!"
      }
    })

    searcher = register("searcher4_#{System.unique_integer([:positive])}")
    conn = search(searcher.token, unique)
    refute Enum.any?(decode(conn)["results"], &(&1["user_id"] == target.user_id))
  end

  test "the limited flag is true when results hit the limit" do
    prefix = "limtest#{System.unique_integer([:positive])}"
    for i <- 1..3, do: register("#{prefix}_#{i}")
    searcher = register("searcher5_#{System.unique_integer([:positive])}")

    conn =
      authed(searcher.token)
      |> jp("/_matrix/client/v3/user_directory/search", %{"search_term" => prefix, "limit" => 2})

    body = decode(conn)
    assert length(body["results"]) == 2
    assert body["limited"] == true
  end
end
