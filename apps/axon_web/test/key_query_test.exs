defmodule AxonWeb.KeyQueryTest do
  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  test "rejects a query with missing or null device_keys while allowing an empty object" do
    alice = register("key_query_required_#{System.unique_integer([:positive])}")

    for body <- [%{}, %{"device_keys" => nil}] do
      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/keys/query", body)

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_BAD_JSON"
    end

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/keys/query", %{"device_keys" => %{}})

    assert conn.status == 200
  end

  test "rejects a device-key query whose user value is an object" do
    alice = register("key_query_object_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/keys/query", %{
        "device_keys" => %{alice.user_id => %{"device" => alice.device_id}}
      })

    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_BAD_JSON"
  end

  test "rejects a device-key query whose device array contains a non-string" do
    alice = register("key_query_non_string_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/keys/query", %{
        "device_keys" => %{alice.user_id => [alice.device_id, 42]}
      })

    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_BAD_JSON"
  end

  test "filters local device keys by requested IDs while an empty array returns all" do
    username = "key_query_filter_#{System.unique_integer([:positive])}"
    alice_1 = register(username)
    alice_2 = login(username)

    upload_device_keys(alice_1)
    upload_device_keys(alice_2)

    targeted =
      authed(alice_1.token)
      |> jp("/_matrix/client/v3/keys/query", %{
        "device_keys" => %{alice_1.user_id => [alice_2.device_id]}
      })

    assert targeted.status == 200

    assert Map.keys(decode(targeted)["device_keys"][alice_1.user_id]) == [
             alice_2.device_id
           ]

    all =
      authed(alice_1.token)
      |> jp("/_matrix/client/v3/keys/query", %{
        "device_keys" => %{alice_1.user_id => []}
      })

    assert all.status == 200

    assert all
           |> decode()
           |> get_in(["device_keys", alice_1.user_id])
           |> Map.keys()
           |> Enum.sort() == Enum.sort([alice_1.device_id, alice_2.device_id])
  end

  defp login(username) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/login",
        Jason.encode!(%{
          "type" => "m.login.password",
          "identifier" => %{"type" => "m.id.user", "user" => username},
          "password" => "Test1234!"
        })
      )

    assert conn.status == 200
    body = decode(conn)
    %{token: body["access_token"], device_id: body["device_id"], user_id: body["user_id"]}
  end

  defp upload_device_keys(device) do
    conn =
      authed(device.token)
      |> jp("/_matrix/client/v3/keys/upload", %{
        "device_keys" => %{
          "user_id" => device.user_id,
          "device_id" => device.device_id,
          "algorithms" => [],
          "keys" => %{"ed25519:#{device.device_id}" => "key_#{device.device_id}"},
          "signatures" => %{}
        }
      })

    assert conn.status == 200
  end
end
