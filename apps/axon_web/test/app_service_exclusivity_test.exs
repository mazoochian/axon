defmodule AxonWeb.AppService.ExclusivityTest do
  @moduledoc """
  Regression coverage for exclusive-namespace enforcement: an AS that
  claims a `users` or `aliases` namespace exclusively is the only party —
  including itself, but not any other AS or ordinary user — allowed to
  create things there.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  @table :axon_appservices

  setup do
    :ets.insert(@table, {:registrations, []})
    on_exit(fn -> :ets.insert(@table, {:registrations, []}) end)
    :ok
  end

  defp put_registration(reg), do: :ets.insert(@table, {:registrations, [reg]})

  defp exclusive_registration(id) do
    %{
      "id" => id,
      "url" => "http://127.0.0.1:1",
      "as_token" => "as-token-#{id}",
      "hs_token" => "hs-token-#{id}",
      "sender_localpart" => "_#{id}_bot",
      "namespaces" => %{
        "users" => [%{"regex" => "@#{id}_.*", "exclusive" => true}],
        "aliases" => [%{"regex" => "##{id}_.*", "exclusive" => true}],
        "rooms" => []
      }
    }
  end

  describe "user registration" do
    test "an ordinary registration inside an AS's exclusive user namespace is rejected" do
      put_registration(exclusive_registration("excl1"))

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/_matrix/client/v3/register",
          Jason.encode!(%{
            "username" => "excl1_takenname",
            "password" => "Test1234!",
            "auth" => %{"type" => "m.login.dummy"}
          })
        )

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_EXCLUSIVE"
    end

    test "an ordinary registration outside any exclusive namespace is unaffected" do
      put_registration(exclusive_registration("excl2"))
      result = register("plain_user_#{System.unique_integer([:positive])}")
      assert result.user_id
    end

    test "the owning AS can register a ghost user inside its own exclusive namespace" do
      reg = exclusive_registration("excl3")
      put_registration(reg)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{reg["as_token"]}")
        |> put_req_header("content-type", "application/json")
        |> post(
          "/_matrix/client/v3/register",
          Jason.encode!(%{"type" => "m.login.application_service", "username" => "excl3_ghost"})
        )

      assert conn.status == 200
      assert decode(conn)["user_id"] == "@excl3_ghost:localhost"
    end

    test "an AS cannot register a ghost user outside its own namespace, even with a valid as_token" do
      reg = exclusive_registration("excl4")
      put_registration(reg)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{reg["as_token"]}")
        |> put_req_header("content-type", "application/json")
        |> post(
          "/_matrix/client/v3/register",
          Jason.encode!(%{"type" => "m.login.application_service", "username" => "someone_else"})
        )

      assert conn.status == 403
      assert decode(conn)["errcode"] == "M_EXCLUSIVE"
    end

    test "m.login.application_service registration with an invalid as_token is rejected" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer not-a-real-as-token")
        |> put_req_header("content-type", "application/json")
        |> post(
          "/_matrix/client/v3/register",
          Jason.encode!(%{"type" => "m.login.application_service", "username" => "whoever"})
        )

      assert conn.status == 401
      assert decode(conn)["errcode"] == "M_MISSING_TOKEN"
    end
  end

  describe "room alias creation" do
    test "an ordinary user cannot claim an alias inside an AS's exclusive namespace" do
      put_registration(exclusive_registration("exclr1"))
      user = register("alias_creator_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)

      conn =
        authed(user.token)
        |> jpu("/_matrix/client/v3/directory/room/%23exclr1_room:localhost", %{
          "room_id" => room_id
        })

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_EXCLUSIVE"
    end

    test "the owning AS (via identity assertion) can claim an alias inside its own namespace" do
      reg = exclusive_registration("exclr2")
      put_registration(reg)

      # The AS acts as its own sender bot to create the room + alias.
      conn =
        authed(reg["as_token"])
        |> jp("/_matrix/client/v3/createRoom", %{"preset" => "public_chat"})

      assert conn.status == 200
      room_id = decode(conn)["room_id"]

      conn2 =
        authed(reg["as_token"])
        |> jpu("/_matrix/client/v3/directory/room/%23exclr2_room:localhost", %{
          "room_id" => room_id
        })

      assert conn2.status == 200
    end

    test "createRoom's room_alias_name is rejected under the same exclusivity rule" do
      put_registration(exclusive_registration("exclr3"))
      user = register("room_creator_#{System.unique_integer([:positive])}")

      conn =
        authed(user.token)
        |> jp("/_matrix/client/v3/createRoom", %{"room_alias_name" => "exclr3_taken"})

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_EXCLUSIVE"
    end

    test "a different AS cannot claim an alias exclusively owned by another AS" do
      owner = exclusive_registration("exclr4")
      other = exclusive_registration("exclr4_other")
      :ets.insert(@table, {:registrations, [owner, other]})

      conn =
        authed(other["as_token"])
        |> jp("/_matrix/client/v3/createRoom", %{"preset" => "public_chat"})

      assert conn.status == 200
      room_id = decode(conn)["room_id"]

      conn2 =
        authed(other["as_token"])
        |> jpu("/_matrix/client/v3/directory/room/%23exclr4_room:localhost", %{
          "room_id" => room_id
        })

      assert conn2.status == 400
      assert decode(conn2)["errcode"] == "M_EXCLUSIVE"
    end
  end
end
