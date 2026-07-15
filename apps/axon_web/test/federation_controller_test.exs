defmodule AxonWeb.FederationControllerTest do
  @moduledoc """
  Integration tests for the full inbound Server-Server API surface —
  `AxonWeb.FederationController`'s 17 routes, gated by the real
  `AxonWeb.Plug.FederationAuth` (X-Matrix signature verification) against a
  real signed counterparty (`AxonFederation.FakeRemoteMatrixServer`).

  Previously this controller had zero test coverage — the single biggest
  gap in the project.
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}
  alias AxonCore.{EventStore, Repo}
  alias AxonRoom.{CreateRoom, RoomProcess}

  @port 18_900
  @server_name "fake-fedctrl.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp decode(conn), do: Jason.decode!(conn.resp_body)

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

  defp signed_post(path, body) do
    header = FakeRemoteMatrixServer.sign_request(@port, "POST", path, body)

    build_conn()
    |> put_req_header("authorization", header)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp new_local_user(prefix) do
    localpart = "#{prefix}_#{System.unique_integer([:positive])}"

    {:ok, %{user_id: user_id}} =
      AxonCore.UserStore.register(localpart, "Test1234!", server_name: "localhost")

    user_id
  end

  # A local RoomProcess.send_event/5 self-join always requires sender ==
  # target (AuthRules rejects joining "on someone else's behalf"), so a
  # remote user can't be seeded as joined that way. apply_remote_event/2 is
  # the real path a federated join takes — use it here too, matching how
  # send_join actually gets a remote member into the room.
  defp join_remote_member(room_id, member_user_id) do
    {last_event_id, depth} = RoomProcess.get_position(room_id)

    pdu =
      signed_remote_event(%{
        "event_id" => "$seedjoin_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.member",
        "state_key" => member_user_id,
        "sender" => member_user_id,
        "content" => %{"membership" => "join"},
        "depth" => depth + 1,
        "prev_events" => if(last_event_id, do: [last_event_id], else: []),
        "origin_server_ts" => System.os_time(:millisecond)
      })

    {:ok, _} = RoomProcess.apply_remote_event(room_id, pdu)
  end

  defp remote_user(prefix), do: "@#{prefix}_#{System.unique_integer([:positive])}:#{@server_name}"

  defp signed_remote_event(fields) do
    FakeRemoteMatrixServer.sign_event(@port, Map.merge(%{"hashes" => %{"sha256" => "x"}}, fields))
  end

  # ---------------------------------------------------------------------------
  # make_join / send_join
  # ---------------------------------------------------------------------------

  describe "GET make_join/2" do
    test "returns a join event template for a public room" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      joiner = remote_user("joiner")

      conn =
        signed_get(
          "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(joiner)}?ver=10&ver=11"
        )

      assert conn.status == 200
      body = decode(conn)
      assert body["event"]["sender"] == joiner
      assert body["event"]["content"]["membership"] == "join"
    end

    test "rejects when the user_id's server doesn't match the requesting origin" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      mismatched_user = "@someone:not-#{@server_name}"

      conn =
        signed_get(
          "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(mismatched_user)}"
        )

      assert conn.status == 403
    end

    test "404s for a room that doesn't exist locally" do
      joiner = remote_user("joiner")

      conn =
        signed_get(
          "/_matrix/federation/v1/make_join/!nonexistent:localhost/#{URI.encode(joiner)}"
        )

      assert conn.status == 404
    end

    test "403s when the join isn't allowed (invite-only, no invite)" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "private_chat")
      joiner = remote_user("joiner")

      conn =
        signed_get(
          "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(joiner)}"
        )

      assert conn.status == 403
    end
  end

  describe "PUT send_join/2" do
    test "applies a valid signed join event and returns state + auth_chain" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      joiner = remote_user("joiner")

      make_join_conn =
        signed_get(
          "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(joiner)}"
        )

      template = decode(make_join_conn)["event"]

      join_event =
        signed_remote_event(
          Map.merge(template, %{
            "event_id" => "$join_#{System.unique_integer([:positive])}",
            "origin_server_ts" => System.os_time(:millisecond)
          })
        )

      path =
        "/_matrix/federation/v2/send_join/#{URI.encode(room_id)}/#{URI.encode(join_event["event_id"])}"

      conn = signed_put(path, join_event)

      assert conn.status == 200
      body = decode(conn)
      assert is_list(body["state"])
      assert EventStore.get_membership(room_id, joiner) == {:ok, "join"}
    end

    test "rejects a malformed join event (wrong type)" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")

      bad_event =
        signed_remote_event(%{
          "event_id" => "$bad_#{System.unique_integer([:positive])}",
          "room_id" => room_id,
          "type" => "m.room.message",
          "content" => %{"membership" => "join"},
          "sender" => remote_user("x"),
          "origin_server_ts" => System.os_time(:millisecond)
        })

      path =
        "/_matrix/federation/v2/send_join/#{URI.encode(room_id)}/#{URI.encode(bad_event["event_id"])}"

      conn = signed_put(path, bad_event)
      assert conn.status == 400
    end

    test "rejects a join event with a bad/missing signature" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      joiner = remote_user("joiner")

      unsigned_event = %{
        "event_id" => "$unsigned_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.member",
        "state_key" => joiner,
        "sender" => joiner,
        "content" => %{"membership" => "join"},
        "origin_server_ts" => System.os_time(:millisecond),
        "origin" => @server_name,
        "signatures" => %{}
      }

      path =
        "/_matrix/federation/v2/send_join/#{URI.encode(room_id)}/#{URI.encode(unsigned_event["event_id"])}"

      conn = signed_put(path, unsigned_event)
      assert conn.status == 403
    end

    test "rejects a join from a banned user (auth check failure)" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      banned = remote_user("banned")

      {:ok, _} =
        RoomProcess.send_event(room_id, owner, "m.room.member", %{"membership" => "ban"},
          state_key: banned
        )

      join_event =
        signed_remote_event(%{
          "event_id" => "$banned_join_#{System.unique_integer([:positive])}",
          "room_id" => room_id,
          "type" => "m.room.member",
          "state_key" => banned,
          "sender" => banned,
          "content" => %{"membership" => "join"},
          "origin_server_ts" => System.os_time(:millisecond)
        })

      path =
        "/_matrix/federation/v2/send_join/#{URI.encode(room_id)}/#{URI.encode(join_event["event_id"])}"

      conn = signed_put(path, join_event)
      assert conn.status == 403
    end
  end

  # ---------------------------------------------------------------------------
  # make_leave / send_leave
  # ---------------------------------------------------------------------------

  describe "make_leave / send_leave" do
    test "make_leave returns a leave event template" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      member = remote_user("member")
      join_remote_member(room_id, member)

      conn =
        signed_get(
          "/_matrix/federation/v1/make_leave/#{URI.encode(room_id)}/#{URI.encode(member)}"
        )

      assert conn.status == 200
      assert decode(conn)["event"]["content"]["membership"] == "leave"
    end

    test "send_leave applies a valid signed leave event" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      member = remote_user("member")
      join_remote_member(room_id, member)

      make_leave_conn =
        signed_get(
          "/_matrix/federation/v1/make_leave/#{URI.encode(room_id)}/#{URI.encode(member)}"
        )

      template = decode(make_leave_conn)["event"]

      leave_event =
        signed_remote_event(
          Map.merge(template, %{
            "event_id" => "$leave_#{System.unique_integer([:positive])}",
            "origin_server_ts" => System.os_time(:millisecond)
          })
        )

      path =
        "/_matrix/federation/v2/send_leave/#{URI.encode(room_id)}/#{URI.encode(leave_event["event_id"])}"

      conn = signed_put(path, leave_event)

      assert conn.status == 200
      assert EventStore.get_membership(room_id, member) == {:ok, "leave"}
    end

    test "send_leave rejects a bad signature" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      member = remote_user("member")

      unsigned = %{
        "event_id" => "$badleave_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.member",
        "state_key" => member,
        "sender" => member,
        "content" => %{"membership" => "leave"},
        "origin_server_ts" => System.os_time(:millisecond),
        "origin" => @server_name,
        "signatures" => %{}
      }

      path =
        "/_matrix/federation/v2/send_leave/#{URI.encode(room_id)}/#{URI.encode(unsigned["event_id"])}"

      conn = signed_put(path, unsigned)
      assert conn.status == 403
    end
  end

  # ---------------------------------------------------------------------------
  # make_knock / send_knock
  # ---------------------------------------------------------------------------

  describe "make_knock / send_knock" do
    test "make_knock returns a knock event template for a knockable room" do
      owner = new_local_user("owner")

      {:ok, room_id} =
        CreateRoom.execute(owner,
          server_name: "localhost",
          initial_state: [
            %{"type" => "m.room.join_rules", "content" => %{"join_rule" => "knock"}}
          ]
        )

      knocker = remote_user("knocker")

      conn =
        signed_get(
          "/_matrix/federation/v1/make_knock/#{URI.encode(room_id)}/#{URI.encode(knocker)}?ver=10"
        )

      assert conn.status == 200
      assert decode(conn)["event"]["content"]["membership"] == "knock"
    end

    test "make_knock 403s when the room doesn't allow knocking" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "private_chat")
      knocker = remote_user("knocker")

      conn =
        signed_get(
          "/_matrix/federation/v1/make_knock/#{URI.encode(room_id)}/#{URI.encode(knocker)}"
        )

      assert conn.status == 403
    end

    test "send_knock applies a valid knock and returns a room state preview" do
      owner = new_local_user("owner")

      {:ok, room_id} =
        CreateRoom.execute(owner,
          server_name: "localhost",
          name: "Knockable",
          initial_state: [
            %{"type" => "m.room.join_rules", "content" => %{"join_rule" => "knock"}}
          ]
        )

      knocker = remote_user("knocker")

      make_knock_conn =
        signed_get(
          "/_matrix/federation/v1/make_knock/#{URI.encode(room_id)}/#{URI.encode(knocker)}"
        )

      template = decode(make_knock_conn)["event"]

      knock_event =
        signed_remote_event(
          Map.merge(template, %{
            "event_id" => "$knock_#{System.unique_integer([:positive])}",
            "origin_server_ts" => System.os_time(:millisecond)
          })
        )

      path =
        "/_matrix/federation/v1/send_knock/#{URI.encode(room_id)}/#{URI.encode(knock_event["event_id"])}"

      conn = signed_put(path, knock_event)

      assert conn.status == 200
      assert is_list(decode(conn)["knock_room_state"])
      assert EventStore.get_membership(room_id, knocker) == {:ok, "knock"}
    end
  end

  # ---------------------------------------------------------------------------
  # send_transaction
  # ---------------------------------------------------------------------------

  describe "PUT send_transaction/2" do
    test "applies a single valid inbound PDU" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      remote_member = remote_user("member")
      join_remote_member(room_id, remote_member)

      {last_event_id, depth} = RoomProcess.get_position(room_id)

      pdu =
        signed_remote_event(%{
          "event_id" => "$txnpdu_#{System.unique_integer([:positive])}",
          "room_id" => room_id,
          "type" => "m.room.message",
          "sender" => remote_member,
          "content" => %{"msgtype" => "m.text", "body" => "hi from federation"},
          "depth" => depth + 1,
          "prev_events" => [last_event_id],
          "origin_server_ts" => System.os_time(:millisecond)
        })

      txn_id = "txn_#{System.unique_integer([:positive])}"
      conn = signed_put("/_matrix/federation/v1/send/#{txn_id}", %{"pdus" => [pdu], "edus" => []})

      assert conn.status == 200
      {new_last_event_id, _} = RoomProcess.get_position(room_id)
      assert new_last_event_id == pdu["event_id"]
    end

    test "a duplicate txn_id is idempotent — replayed without reprocessing" do
      owner = new_local_user("owner")
      {:ok, _room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")

      txn_id = "txn_#{System.unique_integer([:positive])}"
      body = %{"pdus" => [], "edus" => []}

      conn1 = signed_put("/_matrix/federation/v1/send/#{txn_id}", body)
      assert conn1.status == 200

      conn2 = signed_put("/_matrix/federation/v1/send/#{txn_id}", body)
      assert conn2.status == 200
      assert decode(conn2)["pdus"] == %{}

      count =
        Repo.aggregate(
          from(t in "federation_inbound_txns", where: t.txn_id == ^txn_id),
          :count
        )

      assert count == 1
    end

    test "a PDU with a bad signature is soft-failed per-event, transaction still 200s" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")

      unsigned_pdu = %{
        "event_id" => "$unsignedpdu_#{System.unique_integer([:positive])}",
        "room_id" => room_id,
        "type" => "m.room.message",
        "sender" => remote_user("x"),
        "content" => %{"body" => "hi"},
        "depth" => 99,
        "prev_events" => [],
        "origin_server_ts" => System.os_time(:millisecond),
        "origin" => @server_name,
        "signatures" => %{}
      }

      txn_id = "txn_#{System.unique_integer([:positive])}"
      conn = signed_put("/_matrix/federation/v1/send/#{txn_id}", %{"pdus" => [unsigned_pdu]})

      assert conn.status == 200
      assert EventStore.get_event(unsigned_pdu["event_id"]) == {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # get_event / get_state / get_state_ids / backfill / get_missing_events
  # ---------------------------------------------------------------------------

  describe "read-only room data endpoints" do
    setup do
      owner = new_local_user("owner")

      {:ok, room_id} =
        CreateRoom.execute(owner,
          server_name: "localhost",
          preset: "public_chat",
          name: "Readable"
        )

      %{owner: owner, room_id: room_id}
    end

    test "get_event returns a known event, 404s for an unknown one", %{room_id: room_id} do
      {:ok, event} = EventStore.get_state_event(room_id, "m.room.name", "")

      conn = signed_get("/_matrix/federation/v1/event/#{URI.encode(event.event_id)}")
      assert conn.status == 200
      assert [pdu] = decode(conn)["pdus"]
      assert pdu["event_id"] == event.event_id

      conn = signed_get("/_matrix/federation/v1/event/%24nonexistent")
      assert conn.status == 404
    end

    test "get_state returns the room's current state events", %{room_id: room_id} do
      conn = signed_get("/_matrix/federation/v1/state/#{URI.encode(room_id)}")
      assert conn.status == 200
      types = decode(conn)["pdus"] |> Enum.map(& &1["type"])
      assert "m.room.create" in types
      assert "m.room.name" in types
    end

    test "get_state_ids returns state and auth chain event ids", %{room_id: room_id} do
      conn = signed_get("/_matrix/federation/v1/state_ids/#{URI.encode(room_id)}")
      assert conn.status == 200
      body = decode(conn)
      assert is_list(body["pdu_ids"])
      assert is_list(body["auth_chain_ids"])
      refute body["pdu_ids"] == []
    end

    test "backfill returns events older than the given ordering, respecting limit", %{
      room_id: room_id,
      owner: owner
    } do
      for i <- 1..5 do
        RoomProcess.send_event(room_id, owner, "m.room.message", %{"body" => "msg #{i}"})
      end

      conn = signed_get("/_matrix/federation/v1/backfill/#{URI.encode(room_id)}?limit=2")
      assert conn.status == 200
      pdus = decode(conn)["pdus"]
      assert length(pdus) == 2
    end

    test "get_missing_events returns events not in known_ids", %{room_id: room_id, owner: owner} do
      {:ok, e1} = RoomProcess.send_event(room_id, owner, "m.room.message", %{"body" => "one"})

      conn =
        signed_post("/_matrix/federation/v1/get_missing_events/#{URI.encode(room_id)}", %{
          "known_ids" => [e1],
          "limit" => 10
        })

      assert conn.status == 200
      assert is_list(decode(conn)["events"])
    end
  end

  # ---------------------------------------------------------------------------
  # query/directory, query/profile
  # ---------------------------------------------------------------------------

  describe "query_directory / query_profile" do
    test "query_directory resolves a known alias to a room_id" do
      owner = new_local_user("owner")
      localpart = "aliastest#{System.unique_integer([:positive])}"

      {:ok, room_id} =
        CreateRoom.execute(owner, server_name: "localhost", room_alias_name: localpart)

      room_alias = "##{localpart}:localhost"

      # URI.encode/1 deliberately leaves "#" unescaped (it's valid in a path),
      # but here it's a *query value* where an unescaped "#" would be parsed
      # as the start of a fragment — escape it explicitly.
      encoded_alias = room_alias |> URI.encode() |> String.replace("#", "%23")
      conn = signed_get("/_matrix/federation/v1/query/directory?room_alias=#{encoded_alias}")
      assert conn.status == 200
      assert decode(conn)["room_id"] == room_id
    end

    test "query_directory 404s for an unknown alias" do
      conn =
        signed_get("/_matrix/federation/v1/query/directory?room_alias=%23nonexistent:localhost")

      assert conn.status == 404
    end

    test "query_profile returns displayname/avatar_url for a known local user (regression: was querying nonexistent users columns)" do
      user_id = new_local_user("profiled")

      :ok =
        elem(
          AxonCore.UserStore.update_profile(user_id, %{
            displayname: "Cool Name",
            avatar_url: "mxc://localhost/abc"
          }),
          0
        )
        |> then(fn :ok -> :ok end)

      conn = signed_get("/_matrix/federation/v1/query/profile?user_id=#{URI.encode(user_id)}")
      assert conn.status == 200
      body = decode(conn)
      assert body["displayname"] == "Cool Name"
      assert body["avatar_url"] == "mxc://localhost/abc"
    end

    test "query_profile 404s for an unknown user" do
      conn =
        signed_get(
          "/_matrix/federation/v1/query/profile?user_id=#{URI.encode(remote_user("ghost"))}"
        )

      assert conn.status == 404
    end
  end

  # ---------------------------------------------------------------------------
  # E2EE cross-server key exchange
  # ---------------------------------------------------------------------------

  describe "cross-server key exchange" do
    test "query_user_keys returns device keys for local users, filters out remote ones" do
      local_user = new_local_user("keyed")
      remote = remote_user("elsewhere")

      conn =
        signed_post("/_matrix/federation/v1/user/keys/query", %{
          "device_keys" => %{local_user => [], remote => []}
        })

      assert conn.status == 200
      body = decode(conn)
      assert Map.has_key?(body["device_keys"], local_user)
      refute Map.has_key?(body["device_keys"], remote)
    end

    test "claim_user_keys only claims for local users" do
      local_user = new_local_user("claimer")
      remote = remote_user("elsewhere")

      conn =
        signed_post("/_matrix/federation/v1/user/keys/claim", %{
          "one_time_keys" => %{
            local_user => %{"DEV1" => "curve25519"},
            remote => %{"DEV1" => "curve25519"}
          }
        })

      assert conn.status == 200
      body = decode(conn)["one_time_keys"]
      assert body[remote] == %{}
    end

    test "get_user_devices 404s for a non-local user" do
      conn =
        signed_get("/_matrix/federation/v1/user/devices/#{URI.encode(remote_user("notlocal"))}")

      assert conn.status == 404
    end

    test "get_user_devices returns a stream_id and device list for a local user" do
      local_user = new_local_user("devicelist")
      conn = signed_get("/_matrix/federation/v1/user/devices/#{URI.encode(local_user)}")
      assert conn.status == 200
      body = decode(conn)
      assert body["user_id"] == local_user
      assert is_integer(body["stream_id"])
    end
  end

  describe "GET /_matrix/key/v2/query" do
    test "returns this server's own signed key document" do
      conn = signed_post("/_matrix/key/v2/query", %{})
      assert conn.status == 200
      [server_key] = decode(conn)["server_keys"]
      assert server_key["server_name"] == "localhost"
      assert map_size(server_key["verify_keys"]) > 0
    end
  end
end
