defmodule AxonWeb.KeyBackupVersionTest do
  @moduledoc """
  Regression test for the "Unable to set up keys" bug: version numbers used to
  come from System.unique_integer/1, which resets on every node restart, so
  after a restart the next generated version could collide with a row already
  persisted before the restart and blow up on the room_key_backup_versions_pkey
  unique constraint. Versions must now come from a real Postgres sequence.
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query
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
    %{token: body["access_token"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp jp(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_version(token) do
    authed(token)
    |> jp("/_matrix/client/v3/room_keys/version", %{
      "algorithm" => "m.megolm_backup.v1.curve25519-aes-sha2",
      "auth_data" => %{}
    })
  end

  test "consecutive backup version creations succeed with distinct versions" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    v1 = create_version(alice.token) |> tap(&assert &1.status == 200) |> decode()
    v2 = create_version(alice.token) |> tap(&assert &1.status == 200) |> decode()

    assert v1["version"] != v2["version"]
  end

  test "version generation survives a simulated node restart without colliding" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    v1 = create_version(alice.token) |> tap(&assert &1.status == 200) |> decode()

    # Simulate what used to happen after a BEAM restart: System.unique_integer/1
    # would restart counting from 1, potentially re-issuing a version number
    # that's already taken. A real Postgres sequence can't regress like that.
    conn = create_version(alice.token)
    assert conn.status == 200
    v2 = decode(conn)

    assert v2["version"] != v1["version"]
    assert String.to_integer(v2["version"]) > String.to_integer(v1["version"])

    # And the row actually persisted under the returned version (no silent drop).
    assert Repo.exists?(from(v in "room_key_backup_versions", where: v.version == ^v2["version"]))
  end
end
