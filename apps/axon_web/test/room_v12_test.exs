defmodule AxonWeb.RoomV12Test do
  @moduledoc """
  Regression tests for Phase 12's room version 12 support (MSC4297 state-res
  v2.1 + MSC4289 "privilege creators" auth rules + domainless, hash-derived
  room IDs).
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}
  alias AxonCore.EventStore

  @port 19_200
  @server_name "fake-v12.test"

  defp send_state(token, room_id, type, state_key, content) do
    authed(token)
    |> jpu("/_matrix/client/v3/rooms/#{room_id}/state/#{type}/#{state_key}", content)
  end

  describe "room creation" do
    test "a v12 room gets a domainless, hash-derived room_id" do
      alice = register("v12_create_#{System.unique_integer([:positive])}")

      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/createRoom", %{
          "room_version" => "12",
          "preset" => "public_chat"
        })

      assert conn.status == 200
      room_id = decode(conn)["room_id"]

      assert String.starts_with?(room_id, "!")
      refute String.contains?(room_id, ":")

      # The create event itself carries no room_id field on the wire (MSC4297).
      state_conn =
        authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.create")

      assert state_conn.status == 200
      create_content = decode(state_conn)
      assert create_content["room_version"] == "12"
    end

    test "the creator holds implicit infinite power: not listed in power_levels.users, and power_levels state changes work" do
      alice = register("v12_power_#{System.unique_integer([:positive])}")

      room_id =
        create_room(alice.token, %{"room_version" => "12", "preset" => "public_chat"})

      pl_conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.power_levels")

      assert pl_conn.status == 200
      pl = decode(pl_conn)
      refute Map.has_key?(pl["users"] || %{}, alice.user_id)

      # The creator can still gate power-sensitive actions despite no
      # explicit users entry — e.g. raising the room's own state_default.
      conn =
        send_state(
          alice.token,
          room_id,
          "m.room.power_levels",
          "",
          Map.put(pl, "state_default", 60)
        )

      assert conn.status == 200
    end

    test "a power_levels event listing the creator in users is rejected (rule 10.4)" do
      alice = register("v12_rule104_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"room_version" => "12", "preset" => "public_chat"})

      pl_conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.power_levels")

      pl = decode(pl_conn)

      bad_pl = Map.put(pl, "users", Map.put(pl["users"] || %{}, alice.user_id, 100))
      conn = send_state(alice.token, room_id, "m.room.power_levels", "", bad_pl)

      assert conn.status == 403
    end

    test "a non-creator member is still power-gated normally" do
      alice = register("v12_gate_alice_#{System.unique_integer([:positive])}")
      bob = register("v12_gate_bob_#{System.unique_integer([:positive])}")
      room_id = create_room(alice.token, %{"room_version" => "12", "preset" => "public_chat"})

      conn = authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
      assert conn.status == 200

      conn = send_state(bob.token, room_id, "m.room.name", "", %{"name" => "bob was here"})
      assert conn.status == 403
    end

    test "additional_creators (via creation_content) also get infinite power and can't be listed in power_levels.users" do
      alice = register("v12_addl_alice_#{System.unique_integer([:positive])}")
      bob = register("v12_addl_bob_#{System.unique_integer([:positive])}")

      room_id =
        create_room(alice.token, %{
          "room_version" => "12",
          "preset" => "public_chat",
          "creation_content" => %{"additional_creators" => [bob.user_id]}
        })

      conn = authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{})
      assert conn.status == 200

      # bob, an additional_creator, can perform a power-gated action despite
      # never appearing in power_levels.users.
      conn = send_state(bob.token, room_id, "m.room.name", "", %{"name" => "bob co-created this"})
      assert conn.status == 200

      pl_conn =
        authed(alice.token)
        |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.power_levels")

      pl = decode(pl_conn)
      refute Map.has_key?(pl["users"] || %{}, bob.user_id)
    end

    test "a malformed additional_creators entry is rejected at creation time" do
      alice = register("v12_badaddl_#{System.unique_integer([:positive])}")

      conn =
        authed(alice.token)
        |> jp("/_matrix/client/v3/createRoom", %{
          "room_version" => "12",
          "creation_content" => %{"additional_creators" => ["not-a-user-id"]}
        })

      assert conn.status >= 400
    end
  end

  describe "joining a domainless room_id" do
    test "without a via/server_name hint, returns a clear error instead of guessing a bogus server" do
      alice = register("v12_viahint_#{System.unique_integer([:positive])}")
      fake_room_id = "!doesnotexisthash"

      conn = authed(alice.token) |> jp("/_matrix/client/v3/join/#{fake_room_id}", %{})

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_MISSING_PARAM"
    end
  end

  describe "federation: remote join of a locally-hosted v12 room" do
    setup do
      start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
      KeyCache.clear()

      Application.put_env(:axon_federation, :server_overrides, %{
        @server_name => "http://127.0.0.1:#{@port}"
      })

      on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
      :ok
    end

    defp signed_get(path) do
      header = FakeRemoteMatrixServer.sign_request(@port, "GET", path)
      build_conn() |> put_req_header("authorization", header) |> get(path)
    end

    defp signed_put(path, body) do
      header = FakeRemoteMatrixServer.sign_request(@port, "PUT", path, body)

      build_conn()
      |> put_req_header("authorization", header)
      |> put_req_header("content-type", "application/json")
      |> put(path, Jason.encode!(body))
    end

    test "make_join + send_join works for a v12 room, and the create event is omitted from returned state's room_id-bearing shape correctly" do
      owner = register("v12_fed_owner_#{System.unique_integer([:positive])}")
      room_id = create_room(owner.token, %{"room_version" => "12", "preset" => "public_chat"})
      joiner = "@v12_fed_joiner_#{System.unique_integer([:positive])}:#{@server_name}"

      make_join_conn =
        signed_get(
          "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(joiner)}?ver=12"
        )

      assert make_join_conn.status == 200
      body = Jason.decode!(make_join_conn.resp_body)
      assert body["room_version"] == "12"
      template = body["event"]
      assert template["sender"] == joiner
      # v12 rule 3.2: m.room.create must not be an auth event.
      auth_event_ids = template["auth_events"]

      create_event_id_conn =
        authed(owner.token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/m.room.create")

      assert create_event_id_conn.status == 200

      join_event =
        FakeRemoteMatrixServer.sign_event(
          @port,
          Map.merge(template, %{
            "event_id" => "$v12join_#{System.unique_integer([:positive])}",
            "hashes" => %{"sha256" => "x"},
            "origin_server_ts" => System.os_time(:millisecond)
          })
        )

      path =
        "/_matrix/federation/v2/send_join/#{URI.encode(room_id)}/#{URI.encode(join_event["event_id"])}"

      conn = signed_put(path, join_event)

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert is_list(resp["state"])

      # The create event, wherever it appears in returned state, must not
      # carry a room_id field on the wire.
      create_in_state = Enum.find(resp["state"], &(&1["type"] == "m.room.create"))
      refute Map.has_key?(create_in_state, "room_id")
      refute create_event_id_conn |> decode() |> Map.has_key?("room_id")

      assert EventStore.get_membership(room_id, joiner) == {:ok, "join"}
      refute auth_event_ids |> Enum.any?(&(&1 == create_in_state["event_id"]))
    end
  end
end
