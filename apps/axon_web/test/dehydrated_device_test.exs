defmodule AxonWeb.DehydratedDeviceTest do
  @moduledoc """
  Regression test for MSC3814 dehydrated devices, which previously didn't
  exist at all in Axon — every request to
  /_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device 404d,
  which is what broke Element Web's "Key Storage" setup flow.
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query
  alias AxonCore.Repo

  @path "/_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device"

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
      conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp dehydrated_device_payload(device_id) do
    %{
      "device_id" => device_id,
      "device_data" => %{
        "algorithm" => "m.dehydration.v2",
        "device_pickle" => "cipherbytes",
        "nonce" => "abc"
      },
      "initial_device_display_name" => "Dehydrated device",
      "device_keys" => %{
        "user_id" => "ignored_by_server_uses_token_identity",
        "device_id" => device_id,
        "algorithms" => ["m.olm.v1.curve25519-aes-sha2"],
        "keys" => %{"curve25519:#{device_id}" => "fakekey", "ed25519:#{device_id}" => "fakekey2"},
        "signatures" => %{}
      },
      "one_time_keys" => %{"curve25519:AAAA" => "fakeotk"}
    }
  end

  test "GET before any dehydrated device exists 404s" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get(@path)
    assert conn.status == 404
    assert decode(conn)["errcode"] == "M_NOT_FOUND"
  end

  test "PUT without device_keys 400s (mirrors Synapse's validation)" do
    alice = register("alice_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jp(@path, %{"device_id" => "DEH1", "device_data" => %{"algorithm" => "m.dehydration.v2"}})

    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_MISSING_PARAM"
  end

  test "PUT then GET round-trips the dehydrated device" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    device_id = "DEHY_#{System.unique_integer([:positive])}"

    put_conn = authed(alice.token) |> jp(@path, dehydrated_device_payload(device_id))
    assert put_conn.status == 200
    assert decode(put_conn)["device_id"] == device_id

    get_conn = authed(alice.token) |> get(@path)
    assert get_conn.status == 200
    body = decode(get_conn)
    assert body["device_id"] == device_id
    assert body["device_data"]["algorithm"] == "m.dehydration.v2"
  end

  test "PUTting a new dehydrated device replaces and purges the old one" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    old_id = "DEHY_OLD_#{System.unique_integer([:positive])}"
    new_id = "DEHY_NEW_#{System.unique_integer([:positive])}"

    authed(alice.token) |> jp(@path, dehydrated_device_payload(old_id))

    put_conn = authed(alice.token) |> jp(@path, dehydrated_device_payload(new_id))
    assert put_conn.status == 200

    get_conn = authed(alice.token) |> get(@path)
    assert decode(get_conn)["device_id"] == new_id

    refute Repo.exists?(from(d in "devices", where: d.device_id == ^old_id))
    refute Repo.exists?(from(k in "device_keys", where: k.device_id == ^old_id))
  end

  test "events endpoint enforces the dehydrated device belongs to the requester and paginates" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    device_id = "DEHY_#{System.unique_integer([:positive])}"

    put_conn = authed(alice.token) |> jp(@path, dehydrated_device_payload(device_id))
    assert put_conn.status == 200

    # Queue 3 to-device messages destined for the dehydrated device, as if
    # other users had sent Megolm sessions to it.
    for i <- 1..3 do
      Repo.insert_all("to_device_messages", [
        %{
          sender: bob.user_id,
          target_user_id: alice.user_id,
          target_device_id: device_id,
          type: "m.room_key",
          content: %{"index" => i},
          inserted_at: DateTime.utc_now(:microsecond)
        }
      ])
    end

    # Wrong device_id in the path -> 403.
    forbidden =
      authed(alice.token) |> get("#{@path}/not-the-dehydrated-device-id/events")

    assert forbidden.status == 403

    # Paginate two at a time.
    page1 = authed(alice.token) |> get("#{@path}/#{device_id}/events?limit=2")
    assert page1.status == 200
    page1_body = decode(page1)
    assert length(page1_body["events"]) == 2
    assert page1_body["next_batch"]

    page2 =
      authed(alice.token)
      |> get("#{@path}/#{device_id}/events?limit=2&from=#{page1_body["next_batch"]}")

    assert page2.status == 200
    page2_body = decode(page2)
    assert length(page2_body["events"]) == 1
    refute Map.has_key?(page2_body, "next_batch")
  end

  test "DELETE removes the dehydrated device and its keys" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    device_id = "DEHY_#{System.unique_integer([:positive])}"

    authed(alice.token) |> jp(@path, dehydrated_device_payload(device_id))

    del_conn = authed(alice.token) |> delete(@path)
    assert del_conn.status == 200
    assert decode(del_conn)["device_id"] == device_id

    get_conn = authed(alice.token) |> get(@path)
    assert get_conn.status == 404

    refute Repo.exists?(from(d in "devices", where: d.device_id == ^device_id))
  end
end
