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
  alias AxonCrypto.EventHash
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

  defp wait_until(deadline_ms, fun) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("condition not met before deadline")
      else
        Process.sleep(20)
        wait_until(deadline_ms, fun)
      end
    end
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

  # Complement's srv.MustJoinRoom does a *real* make_join -> send_join HTTP
  # round trip (federation/server.go), not a direct RoomProcess injection —
  # used here so the send_* validation cluster's setup matches Complement's
  # exactly, in case the divergence turns out to be in that round trip
  # itself rather than in the later junk-event rejections.
  defp join_via_http(room_id, member_user_id, room_version \\ "11") do
    make_join_conn =
      signed_get(
        "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(member_user_id)}"
      )

    assert make_join_conn.status == 200
    template = decode(make_join_conn)["event"]

    join_event =
      signed_remote_event(
        Map.merge(template, %{
          "event_id" => "$httpjoin_#{System.unique_integer([:positive])}",
          "origin_server_ts" => System.os_time(:millisecond)
        }),
        room_version
      )

    path =
      "/_matrix/federation/v2/send_join/#{URI.encode(room_id)}/#{URI.encode(join_event["event_id"])}"

    conn = signed_put(path, join_event)
    assert conn.status == 200, "join_via_http setup failed: #{conn.status} #{conn.resp_body}"
    :ok
  end

  defp remote_user(prefix), do: "@#{prefix}_#{System.unique_integer([:positive])}:#{@server_name}"

  # room_version matters: the signature is computed over the *redacted* event
  # and the redaction algorithm differs by version (v11 dropped origin,
  # membership and prev_state from the surviving top-level keys), so signing a
  # v7 room's event as if it were v11 produces a signature axon correctly
  # refuses.
  defp signed_remote_event(fields, room_version \\ "11") do
    FakeRemoteMatrixServer.sign_event(
      @port,
      Map.merge(%{"hashes" => %{"sha256" => "x"}}, fields),
      room_version
    )
  end

  # ---- port-parameterized variants (multi-server relay tests only, which
  # need arbitrary/dynamic fake servers rather than the shared @port) ----

  defp remote_user_at(port, prefix),
    do:
      "@#{prefix}_#{System.unique_integer([:positive])}:#{FakeRemoteMatrixServer.server_name(port)}"

  defp signed_get_at(port, path) do
    header = FakeRemoteMatrixServer.sign_request(port, "GET", path)
    build_conn() |> put_req_header("authorization", header) |> get(path)
  end

  defp signed_put_at(port, path, body) do
    header = FakeRemoteMatrixServer.sign_request(port, "PUT", path, body)

    build_conn()
    |> put_req_header("authorization", header)
    |> put_req_header("content-type", "application/json")
    |> put(path, Jason.encode!(body))
  end

  defp signed_remote_event_at(port, fields) do
    FakeRemoteMatrixServer.sign_event(port, Map.merge(%{"hashes" => %{"sha256" => "x"}}, fields))
  end

  defp join_remote_member_at(port, room_id, member_user_id) do
    {last_event_id, depth} = RoomProcess.get_position(room_id)

    pdu =
      signed_remote_event_at(port, %{
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

  defp pdus_contain_event_id?(body, event_id) do
    (body["pdus"] || []) |> Enum.any?(&(&1["event_id"] == event_id))
  end

  # Mirrors Complement's testValidationForSendMembershipEndpoint
  # (tests/federation_room_join_test.go): a joined remote member (charlie)
  # tries to slip a range of non-conforming events through a send_join /
  # send_leave / send_knock endpoint, and every single one of them must be
  # rejected with 400 — a regular non-member event, a non-state
  # m.room.member event, an otherwise-well-formed membership event of every
  # *other* membership type, and a correctly-typed membership event whose
  # state_key doesn't match its sender. Complement only asserts the status
  # code (400), not an errcode, for this cluster.
  defp assert_membership_endpoint_rejects_junk(base_path, room_id, charlie, expected_membership) do
    assert_rejects = fn fields ->
      event =
        signed_remote_event(
          Map.merge(
            %{
              "room_id" => room_id,
              "event_id" => "$junk_#{System.unique_integer([:positive])}",
              "origin_server_ts" => System.os_time(:millisecond)
            },
            fields
          )
        )

      path = "#{base_path}/#{URI.encode(room_id)}/#{URI.encode(event["event_id"])}"
      conn = signed_put(path, event)

      assert conn.status == 400,
             "expected 400 for #{inspect(fields)}, got #{conn.status}: #{conn.resp_body}"
    end

    # regular (non-membership) event
    assert_rejects.(%{
      "type" => "m.room.message",
      "sender" => charlie,
      "content" => %{"body" => "bzz"}
    })

    # non-state membership event (no state_key at all)
    assert_rejects.(%{
      "type" => "m.room.member",
      "sender" => charlie,
      "content" => %{"body" => "bzz"}
    })

    # every *other* membership type, correctly self-targeted
    for membership <- ["join", "leave", "knock", "invite"], membership != expected_membership do
      assert_rejects.(%{
        "type" => "m.room.member",
        "sender" => charlie,
        "state_key" => charlie,
        "content" => %{"membership" => membership}
      })
    end

    # right membership, but mismatched state_key
    assert_rejects.(%{
      "type" => "m.room.member",
      "sender" => charlie,
      "state_key" => remote_user("doris"),
      "content" => %{"membership" => expected_membership}
    })
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

  describe "PUT invite/2" do
    # Room versions 3+ never carry "event_id" on the wire (it's derived from
    # the reference hash) — this is the shape a real inviting server (and
    # Complement) actually sends. Regression for a 500 that hit every
    # invite-related Complement test (TestIsDirectFlagFederation, most of
    # TestFederationRoomsInvite): EventStore.insert_event/2 got a nil
    # event_id and the changeset's NOT NULL violation fell through
    # FallbackController's catch-all as an opaque 500 M_UNKNOWN.
    test "accepts an invite for a room we've never seen, with no event_id on the wire" do
      room_id = "!invite_#{System.unique_integer([:positive])}:#{@server_name}"
      inviter = remote_user("inviter")
      invitee = new_local_user("invitee")

      event =
        signed_remote_event(%{
          "room_id" => room_id,
          "type" => "m.room.member",
          "state_key" => invitee,
          "sender" => inviter,
          "content" => %{"membership" => "invite", "is_direct" => true},
          "depth" => 1,
          "prev_events" => [],
          "origin_server_ts" => System.os_time(:millisecond)
        })
        |> Map.delete("event_id")

      refute Map.has_key?(event, "event_id")

      conn =
        signed_put(
          "/_matrix/federation/v2/invite/#{URI.encode(room_id)}/#{URI.encode(EventHash.reference_hash(event, "11"))}",
          %{"room_version" => "11", "event" => event, "invite_room_state" => []}
        )

      assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"

      returned_event = decode(conn)["event"]
      assert is_binary(returned_event["event_id"])
      assert returned_event["content"]["is_direct"] == true
      assert EventStore.get_membership(room_id, invitee) == {:ok, "invite"}
    end

    test "still works when the wire event already carries an event_id (older room versions)" do
      room_id = "!invite_#{System.unique_integer([:positive])}:#{@server_name}"
      inviter = remote_user("inviter")
      invitee = new_local_user("invitee")
      event_id = "$invite_#{System.unique_integer([:positive])}"

      event =
        signed_remote_event(
          %{
            "event_id" => event_id,
            "room_id" => room_id,
            "type" => "m.room.member",
            "state_key" => invitee,
            "sender" => inviter,
            "content" => %{"membership" => "invite"},
            "depth" => 1,
            "prev_events" => [],
            "origin_server_ts" => System.os_time(:millisecond)
          },
          "6"
        )

      conn =
        signed_put(
          "/_matrix/federation/v2/invite/#{URI.encode(room_id)}/#{URI.encode(event_id)}",
          %{"room_version" => "6", "event" => event, "invite_room_state" => []}
        )

      assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
      assert decode(conn)["event"]["event_id"] == event_id
      assert EventStore.get_membership(room_id, invitee) == {:ok, "invite"}
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
  # send_join / send_leave / send_knock validation cluster
  #
  # Pins Complement's testValidationForSendMembershipEndpoint (shared by
  # TestCannotSendNonJoinViaSendJoin{V1,V2}, TestCannotSendNonLeaveViaSendLeave{V1,V2},
  # TestCannotSendNonKnockViaSendKnock, TestCannotSendKnockViaSendKnockInMSC3787Room)
  # and TestBannedUserCannotSendJoin (federation_room_join_test.go).
  # ---------------------------------------------------------------------------

  describe "send_join/send_leave/send_knock validation cluster (Complement parity)" do
    test "send_join v2 rejects anything but a self-targeted join" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      charlie = remote_user("charlie")
      join_via_http(room_id, charlie)

      assert_membership_endpoint_rejects_junk(
        "/_matrix/federation/v2/send_join",
        room_id,
        charlie,
        "join"
      )
    end

    test "send_join v1 rejects anything but a self-targeted join" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      charlie = remote_user("charlie")
      join_via_http(room_id, charlie)

      assert_membership_endpoint_rejects_junk(
        "/_matrix/federation/v1/send_join",
        room_id,
        charlie,
        "join"
      )
    end

    test "send_leave v2 rejects anything but a self-targeted leave" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      charlie = remote_user("charlie")
      join_via_http(room_id, charlie)

      assert_membership_endpoint_rejects_junk(
        "/_matrix/federation/v2/send_leave",
        room_id,
        charlie,
        "leave"
      )
    end

    test "send_leave v1 rejects anything but a self-targeted leave" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      charlie = remote_user("charlie")
      join_via_http(room_id, charlie)

      assert_membership_endpoint_rejects_junk(
        "/_matrix/federation/v1/send_leave",
        room_id,
        charlie,
        "leave"
      )
    end

    test "send_knock rejects anything but a self-targeted knock (room v7)" do
      owner = new_local_user("owner")

      room_version = "7"

      {:ok, room_id} =
        CreateRoom.execute(owner,
          server_name: "localhost",
          preset: "public_chat",
          version: room_version
        )

      charlie = remote_user("charlie")
      join_via_http(room_id, charlie, room_version)

      assert_membership_endpoint_rejects_junk(
        "/_matrix/federation/v1/send_knock",
        room_id,
        charlie,
        "knock"
      )
    end

    test "send_knock rejects anything but a self-targeted knock (MSC3787 room v10)" do
      owner = new_local_user("owner")

      room_version = "10"

      {:ok, room_id} =
        CreateRoom.execute(owner,
          server_name: "localhost",
          preset: "public_chat",
          version: room_version
        )

      charlie = remote_user("charlie")
      join_via_http(room_id, charlie, room_version)

      assert_membership_endpoint_rejects_junk(
        "/_matrix/federation/v1/send_knock",
        room_id,
        charlie,
        "knock"
      )
    end

    # TestBannedUserCannotSendJoin: charlie is banned from the room, then
    # runs make_join for a *different*, unbanned user (charlie2), swaps the
    # sender/state_key on the resulting event back to himself, and signs it
    # with his own server key. The event's own auth_events reflect
    # charlie2's (empty) prior membership, not charlie's ban — so this only
    # works if the resident server trusts the submitted auth_events for the
    # authorization decision instead of authorizing against the room's real,
    # live state. Must still 403 M_FORBIDDEN, and the ban must survive.
    test "send_join rejects a banned user's join even when auth_events are borrowed from an unbanned user's make_join" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      charlie = remote_user("charlie")
      charlie2 = remote_user("charlie2")

      {:ok, _} =
        RoomProcess.send_event(room_id, owner, "m.room.member", %{"membership" => "ban"},
          state_key: charlie
        )

      make_join_conn =
        signed_get(
          "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(charlie2)}"
        )

      assert make_join_conn.status == 200
      template = decode(make_join_conn)["event"]

      switcheroo_event =
        signed_remote_event(
          Map.merge(template, %{
            "sender" => charlie,
            "state_key" => charlie,
            "event_id" => "$switcheroo_#{System.unique_integer([:positive])}",
            "origin_server_ts" => System.os_time(:millisecond)
          })
        )

      path =
        "/_matrix/federation/v2/send_join/#{URI.encode(room_id)}/#{URI.encode(switcheroo_event["event_id"])}"

      conn = signed_put(path, switcheroo_event)

      assert conn.status == 403
      assert decode(conn)["errcode"] == "M_FORBIDDEN"
      assert EventStore.get_membership(room_id, charlie) == {:ok, "ban"}
    end

    # Companion coverage for the same scenario at make_join itself (the
    # non-switcheroo case): a banned user directly requesting make_join for
    # themselves must also be refused up front.
    test "make_join rejects a banned user's own request" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      charlie = remote_user("charlie")

      {:ok, _} =
        RoomProcess.send_event(room_id, owner, "m.room.member", %{"membership" => "ban"},
          state_key: charlie
        )

      conn =
        signed_get(
          "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(charlie)}"
        )

      assert conn.status == 403
      assert decode(conn)["errcode"] == "M_FORBIDDEN"
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
  # send_transaction — ancestry-gap catch-up (AxonFederation.Backfill)
  # ---------------------------------------------------------------------------

  describe "PUT send_transaction/2 with an ancestry gap" do
    test "fetches a missing single-hop ancestor via get_missing_events before applying the PDU" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      remote_member = remote_user("member")
      join_remote_member(room_id, remote_member)

      {last_event_id, depth} = RoomProcess.get_position(room_id)

      # E1 never gets sent to axon directly — it only exists on "the
      # remote", reachable via get_missing_events — so axon starts out with
      # a genuine gap: E2 (below) references E1, which we've never seen.
      missing_event =
        signed_remote_event(%{
          "event_id" => "$gapmissing_#{System.unique_integer([:positive])}",
          "room_id" => room_id,
          "type" => "m.room.message",
          "sender" => remote_member,
          "content" => %{"msgtype" => "m.text", "body" => "the missing one"},
          "depth" => depth + 1,
          "prev_events" => [last_event_id],
          "origin_server_ts" => System.os_time(:millisecond)
        })

      FakeRemoteMatrixServer.put_response(
        @port,
        {"POST", ~r{^/_matrix/federation/v1/get_missing_events/}},
        200,
        %{"events" => [missing_event]}
      )

      pdu =
        signed_remote_event(%{
          "event_id" => "$gaphead_#{System.unique_integer([:positive])}",
          "room_id" => room_id,
          "type" => "m.room.message",
          "sender" => remote_member,
          "content" => %{"msgtype" => "m.text", "body" => "the one that arrived"},
          "depth" => depth + 2,
          "prev_events" => [missing_event["event_id"]],
          "origin_server_ts" => System.os_time(:millisecond)
        })

      txn_id = "txn_#{System.unique_integer([:positive])}"
      conn = signed_put("/_matrix/federation/v1/send/#{txn_id}", %{"pdus" => [pdu], "edus" => []})

      assert conn.status == 200

      assert {:ok, _} = EventStore.get_event(missing_event["event_id"])
      assert {:ok, _} = EventStore.get_event(pdu["event_id"])

      {new_last_event_id, _} = RoomProcess.get_position(room_id)
      assert new_last_event_id == pdu["event_id"]

      requests = FakeRemoteMatrixServer.requests(@port)
      assert Enum.any?(requests, &(&1.path =~ "/get_missing_events/"))
    end

    test "falls back to backfill when get_missing_events comes back empty" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      remote_member = remote_user("member")
      join_remote_member(room_id, remote_member)

      {last_event_id, depth} = RoomProcess.get_position(room_id)

      missing_event =
        signed_remote_event(%{
          "event_id" => "$gapbf_#{System.unique_integer([:positive])}",
          "room_id" => room_id,
          "type" => "m.room.message",
          "sender" => remote_member,
          "content" => %{"msgtype" => "m.text", "body" => "found via backfill"},
          "depth" => depth + 1,
          "prev_events" => [last_event_id],
          "origin_server_ts" => System.os_time(:millisecond)
        })

      FakeRemoteMatrixServer.put_response(
        @port,
        {"POST", ~r{^/_matrix/federation/v1/get_missing_events/}},
        200,
        %{"events" => []}
      )

      FakeRemoteMatrixServer.put_response(
        @port,
        {"GET", ~r{^/_matrix/federation/v1/backfill/}},
        200,
        %{"pdus" => [missing_event]}
      )

      pdu =
        signed_remote_event(%{
          "event_id" => "$gapbfhead_#{System.unique_integer([:positive])}",
          "room_id" => room_id,
          "type" => "m.room.message",
          "sender" => remote_member,
          "content" => %{"msgtype" => "m.text", "body" => "head after backfill"},
          "depth" => depth + 2,
          "prev_events" => [missing_event["event_id"]],
          "origin_server_ts" => System.os_time(:millisecond)
        })

      txn_id = "txn_#{System.unique_integer([:positive])}"
      conn = signed_put("/_matrix/federation/v1/send/#{txn_id}", %{"pdus" => [pdu], "edus" => []})

      assert conn.status == 200
      assert {:ok, _} = EventStore.get_event(missing_event["event_id"])
      assert {:ok, _} = EventStore.get_event(pdu["event_id"])

      requests = FakeRemoteMatrixServer.requests(@port)
      assert Enum.any?(requests, &(&1.path =~ "/backfill/"))
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

    test "event_auth returns the requested event's transitive auth chain, not the event itself",
         %{room_id: room_id} do
      {:ok, name_event} = EventStore.get_state_event(room_id, "m.room.name", "")

      conn =
        signed_get(
          "/_matrix/federation/v1/event_auth/#{URI.encode(room_id)}/#{URI.encode(name_event.event_id)}"
        )

      assert conn.status == 200
      auth_chain_ids = decode(conn)["auth_chain"] |> Enum.map(& &1["event_id"])

      refute name_event.event_id in auth_chain_ids
      assert Enum.sort(auth_chain_ids) == Enum.sort(name_event.auth_event_ids)
    end

    test "event_auth 404s for an unknown event", %{room_id: room_id} do
      conn = signed_get("/_matrix/federation/v1/event_auth/#{URI.encode(room_id)}/%24nonexistent")
      assert conn.status == 404
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

    test "get_missing_events walks prev_events from latest_events back to (not including) earliest_events, oldest first",
         %{room_id: room_id, owner: owner} do
      {:ok, earliest} = RoomProcess.send_event(room_id, owner, "m.room.message", %{"body" => "e"})
      {:ok, e1} = RoomProcess.send_event(room_id, owner, "m.room.message", %{"body" => "one"})
      {:ok, e2} = RoomProcess.send_event(room_id, owner, "m.room.message", %{"body" => "two"})
      {:ok, latest} = RoomProcess.send_event(room_id, owner, "m.room.message", %{"body" => "l"})

      conn =
        signed_post("/_matrix/federation/v1/get_missing_events/#{URI.encode(room_id)}", %{
          "earliest_events" => [earliest],
          "latest_events" => [latest],
          "limit" => 10
        })

      assert conn.status == 200
      event_ids = decode(conn)["events"] |> Enum.map(& &1["event_id"])

      assert event_ids == [e1, e2, latest]
    end

    test "get_missing_events respects limit", %{room_id: room_id, owner: owner} do
      {:ok, earliest} = RoomProcess.send_event(room_id, owner, "m.room.message", %{"body" => "e"})

      for i <- 1..5 do
        RoomProcess.send_event(room_id, owner, "m.room.message", %{"body" => "msg #{i}"})
      end

      {latest, _} = RoomProcess.get_position(room_id)

      conn =
        signed_post("/_matrix/federation/v1/get_missing_events/#{URI.encode(room_id)}", %{
          "earliest_events" => [earliest],
          "latest_events" => [latest],
          "limit" => 2
        })

      assert length(decode(conn)["events"]) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # query/directory, query/profile
  # ---------------------------------------------------------------------------

  describe "GET /_matrix/federation/v1/hierarchy/:room_id" do
    setup do
      owner = new_local_user("spaceowner")

      {:ok, space_id} =
        CreateRoom.execute(owner,
          server_name: "localhost",
          preset: "public_chat",
          name: "The Space",
          creation_content: %{"type" => "m.space"}
        )

      {:ok, child_id} =
        CreateRoom.execute(owner,
          server_name: "localhost",
          preset: "public_chat",
          name: "Public Child"
        )

      {:ok, private_child_id} =
        CreateRoom.execute(owner, server_name: "localhost", preset: "private_chat")

      for target <- [child_id, private_child_id] do
        {:ok, _} =
          RoomProcess.send_event(space_id, owner, "m.space.child", %{"via" => ["localhost"]},
            state_key: target
          )
      end

      %{owner: owner, space_id: space_id, child_id: child_id, private_child_id: private_child_id}
    end

    test "returns the space summary plus its accessible children", ctx do
      conn = signed_get("/_matrix/federation/v1/hierarchy/#{URI.encode(ctx.space_id)}")
      assert conn.status == 200
      body = decode(conn)

      assert body["room"]["room_id"] == ctx.space_id
      assert body["room"]["name"] == "The Space"
      assert body["room"]["room_type"] == "m.space"
      assert body["room"]["join_rule"] == "public"
      assert is_integer(body["room"]["num_joined_members"])

      # children_state carries the m.space.child events themselves
      child_keys = Enum.map(body["room"]["children_state"], & &1["state_key"])
      assert ctx.child_id in child_keys

      # the public child is summarised; the private one is not
      summarised = Enum.map(body["children"], & &1["room_id"])
      assert ctx.child_id in summarised
      refute ctx.private_child_id in summarised
      assert ctx.private_child_id in body["inaccessible_children"]
    end

    test "404s for a room this server doesn't have" do
      conn = signed_get("/_matrix/federation/v1/hierarchy/#{URI.encode("!nope:localhost")}")
      assert conn.status == 404
      assert %{"errcode" => "M_NOT_FOUND"} = decode(conn)
    end

    test "404s for a room the requesting server may not see", ctx do
      conn = signed_get("/_matrix/federation/v1/hierarchy/#{URI.encode(ctx.private_child_id)}")
      assert conn.status == 404
    end

    test "suggested_only filters children_state down to suggested links", ctx do
      conn =
        signed_get(
          "/_matrix/federation/v1/hierarchy/#{URI.encode(ctx.space_id)}?suggested_only=true"
        )

      assert conn.status == 200
      # No child was marked suggested, so nothing survives the filter.
      assert decode(conn)["room"]["children_state"] == []
      assert decode(conn)["children"] == []
    end
  end

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

    test "claim_user_keys only claims for local users, and omits a user nothing was claimed for" do
      local_user = new_local_user("claimer")
      remote = remote_user("elsewhere")

      conn =
        signed_post("/_matrix/federation/v1/user/keys/claim", %{
          "one_time_keys" => %{
            # No key uploaded for local_user's "DEV1" — nothing to claim.
            local_user => %{"DEV1" => "curve25519"},
            remote => %{"DEV1" => "curve25519"}
          }
        })

      assert conn.status == 200
      body = decode(conn)["one_time_keys"]
      refute Map.has_key?(body, remote)
      refute Map.has_key?(body, local_user)
    end

    test "claim_user_keys returns an uploaded key once, then omits the user once exhausted" do
      local_user = new_local_user("claimer2")
      key_json = %{"key" => "fake_curve25519_key_value"}

      Repo.insert_all("one_time_keys", [
        %{
          user_id: local_user,
          device_id: "DEV1",
          algorithm: "curve25519",
          key_id: "curve25519:AAAAAA",
          key_json: key_json,
          claimed: false,
          inserted_at: DateTime.utc_now(:microsecond)
        }
      ])

      request = %{"one_time_keys" => %{local_user => %{"DEV1" => "curve25519"}}}

      conn1 = signed_post("/_matrix/federation/v1/user/keys/claim", request)
      assert decode(conn1)["one_time_keys"][local_user]["DEV1"] == %{"curve25519:AAAAAA" => key_json}

      conn2 = signed_post("/_matrix/federation/v1/user/keys/claim", request)
      refute Map.has_key?(decode(conn2)["one_time_keys"], local_user)
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

  # ---------------------------------------------------------------------------
  # m.room.server_acl enforcement (AxonRoom.ServerAcl)
  # ---------------------------------------------------------------------------

  describe "m.room.server_acl enforcement" do
    defp deny_fake_server(room_id, owner) do
      {:ok, _} =
        RoomProcess.send_event(
          room_id,
          owner,
          "m.room.server_acl",
          %{"allow" => ["*"], "allow_ip_literals" => true, "deny" => [@server_name]},
          state_key: ""
        )
    end

    test "a PDU from a denied server is soft-failed, not applied" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      remote_member = remote_user("member")
      join_remote_member(room_id, remote_member)
      deny_fake_server(room_id, owner)

      {last_event_id, depth} = RoomProcess.get_position(room_id)

      pdu =
        signed_remote_event(%{
          "event_id" => "$acldenied_#{System.unique_integer([:positive])}",
          "room_id" => room_id,
          "type" => "m.room.message",
          "sender" => remote_member,
          "content" => %{"msgtype" => "m.text", "body" => "should be blocked"},
          "depth" => depth + 1,
          "prev_events" => [last_event_id],
          "origin_server_ts" => System.os_time(:millisecond)
        })

      txn_id = "txn_#{System.unique_integer([:positive])}"
      conn = signed_put("/_matrix/federation/v1/send/#{txn_id}", %{"pdus" => [pdu], "edus" => []})

      assert conn.status == 200
      assert Map.has_key?(decode(conn)["pdus"], pdu["event_id"])
      assert EventStore.get_event(pdu["event_id"]) == {:error, :not_found}
    end

    test "a pre-existing member of a now-denied server keeps their membership" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      remote_member = remote_user("member")
      join_remote_member(room_id, remote_member)
      deny_fake_server(room_id, owner)

      assert EventStore.get_membership(room_id, remote_member) == {:ok, "join"}
    end

    test "make_join 403s when the origin server is denied by the room's ACL" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      deny_fake_server(room_id, owner)
      joiner = remote_user("joiner")

      conn =
        signed_get(
          "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(joiner)}"
        )

      assert conn.status == 403
      assert decode(conn)["errcode"] == "M_FORBIDDEN"
    end

    test "send_join 403s when the origin server is denied" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      joiner = remote_user("joiner")

      make_join_conn =
        signed_get(
          "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(joiner)}"
        )

      template = decode(make_join_conn)["event"]
      deny_fake_server(room_id, owner)

      join_event =
        signed_remote_event(
          Map.merge(template, %{
            "event_id" => "$acljoin_#{System.unique_integer([:positive])}",
            "origin_server_ts" => System.os_time(:millisecond)
          })
        )

      path =
        "/_matrix/federation/v2/send_join/#{URI.encode(room_id)}/#{URI.encode(join_event["event_id"])}"

      conn = signed_put(path, join_event)
      assert conn.status == 403
      assert decode(conn)["errcode"] == "M_FORBIDDEN"
    end

    test "get_state / get_state_ids / backfill / get_missing_events 403 when the origin is denied" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      deny_fake_server(room_id, owner)

      assert signed_get("/_matrix/federation/v1/state/#{URI.encode(room_id)}").status == 403
      assert signed_get("/_matrix/federation/v1/state_ids/#{URI.encode(room_id)}").status == 403
      assert signed_get("/_matrix/federation/v1/backfill/#{URI.encode(room_id)}").status == 403

      conn =
        signed_post("/_matrix/federation/v1/get_missing_events/#{URI.encode(room_id)}", %{
          "known_ids" => []
        })

      assert conn.status == 403
    end

    test "a typing EDU from a denied server is dropped" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      remote_member = remote_user("member")
      join_remote_member(room_id, remote_member)
      deny_fake_server(room_id, owner)

      typing_edu = %{
        "edu_type" => "m.typing",
        "content" => %{"room_id" => room_id, "user_id" => remote_member, "typing" => true}
      }

      txn_id = "txn_#{System.unique_integer([:positive])}"

      conn =
        signed_put("/_matrix/federation/v1/send/#{txn_id}", %{
          "pdus" => [],
          "edus" => [typing_edu]
        })

      assert conn.status == 200
      refute remote_member in AxonSync.Typing.typing_user_ids(room_id)
    end

    test "a receipt EDU from a denied server is dropped" do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")
      remote_member = remote_user("member")
      join_remote_member(room_id, remote_member)

      {:ok, msg_event_id} =
        RoomProcess.send_event(room_id, owner, "m.room.message", %{
          "msgtype" => "m.text",
          "body" => "anchor"
        })

      deny_fake_server(room_id, owner)

      receipt_edu = %{
        "edu_type" => "m.receipt",
        "content" => %{
          room_id => %{
            "m.read" => %{
              remote_member => %{"event_ids" => [msg_event_id], "data" => %{"ts" => 1}}
            }
          }
        }
      }

      txn_id = "txn_#{System.unique_integer([:positive])}"

      conn =
        signed_put("/_matrix/federation/v1/send/#{txn_id}", %{
          "pdus" => [],
          "edus" => [receipt_edu]
        })

      assert conn.status == 200

      count =
        Repo.aggregate(
          from(r in "receipts", where: r.room_id == ^room_id and r.user_id == ^remote_member),
          :count
        )

      assert count == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-server relay: send_join/leave/knock must fan the event out to the
  # room's OTHER resident servers, not just apply it locally. The acting
  # user's own server only knows about the one server it went through
  # (make_join/send_join etc. are the first time it learns the room's
  # state at all) — this resident server is the only one positioned to
  # tell everyone else. Before this fix, RoomProcess.apply_remote_event/2
  # never relayed at all, so a 3rd+ server never learned about a join/
  # leave/knock that happened via a 2nd server — room membership never
  # converged across more than 2 homeservers.
  # ---------------------------------------------------------------------------

  describe "send_join/leave/knock relay to a room's other resident servers" do
    # Deliberately NOT @port/@server_name (shared, reused across every
    # other test in this file) — AxonFederation.OutboundQueue's
    # per-destination concurrency/circuit-breaker state lives in a global
    # ETS table, not reset between tests, so a real-delivery test sharing
    # a destination name with dozens of others became flaky (an unrelated
    # earlier test's in-flight/failed delivery to the same name could trip
    # the breaker right as one of these ran). Fresh, uniquely-named/ported
    # servers per test sidesteps that entirely.
    setup do
      port_a = 18_910 + System.unique_integer([:positive, :monotonic])
      port_b = 18_910 + System.unique_integer([:positive, :monotonic])
      server_a = "fake-relay-a-#{System.unique_integer([:positive])}.test"
      server_b = "fake-relay-b-#{System.unique_integer([:positive])}.test"

      start_supervised!({FakeRemoteMatrixServer, port: port_a, server_name: server_a})
      start_supervised!({FakeRemoteMatrixServer, port: port_b, server_name: server_b})

      Application.put_env(:axon_federation, :server_overrides, %{
        server_a => "http://127.0.0.1:#{port_a}",
        server_b => "http://127.0.0.1:#{port_b}"
      })

      %{port_a: port_a, port_b: port_b, server_a: server_a, server_b: server_b}
    end

    test "a join via send_join is relayed to the room's other resident server", %{
      port_a: port_a,
      port_b: port_b
    } do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")

      # bob (server A) is already resident.
      bob = remote_user_at(port_a, "bob")
      join_remote_member_at(port_a, room_id, bob)

      # charlie (server B) now joins through axon — the only server
      # charlie's own server talked to. axon must relay charlie's join to
      # bob's server on its own.
      charlie = remote_user_at(port_b, "charlie")

      make_join_conn =
        signed_get_at(
          port_b,
          "/_matrix/federation/v1/make_join/#{URI.encode(room_id)}/#{URI.encode(charlie)}"
        )

      template = decode(make_join_conn)["event"]

      join_event =
        signed_remote_event_at(
          port_b,
          Map.merge(template, %{
            "event_id" => "$relayjoin_#{System.unique_integer([:positive])}",
            "origin_server_ts" => System.os_time(:millisecond)
          })
        )

      path =
        "/_matrix/federation/v2/send_join/#{URI.encode(room_id)}/#{URI.encode(join_event["event_id"])}"

      conn = signed_put_at(port_b, path, join_event)
      assert conn.status == 200

      wait_until(System.monotonic_time(:millisecond) + 5_000, fn ->
        Enum.any?(FakeRemoteMatrixServer.requests(port_a), fn req ->
          req.method == "PUT" and req.path =~ "/_matrix/federation/v1/send/" and
            pdus_contain_event_id?(req.body, join_event["event_id"])
        end)
      end)

      # ...but NOT relayed back to charlie's own server — it already has
      # the event (it built and signed it).
      refute Enum.any?(FakeRemoteMatrixServer.requests(port_b), fn req ->
               req.method == "PUT" and req.path =~ "/_matrix/federation/v1/send/" and
                 pdus_contain_event_id?(req.body, join_event["event_id"])
             end)
    end

    test "a leave via send_leave is relayed to the room's other resident server", %{
      port_a: port_a,
      port_b: port_b
    } do
      owner = new_local_user("owner")
      {:ok, room_id} = CreateRoom.execute(owner, server_name: "localhost", preset: "public_chat")

      bob = remote_user_at(port_a, "bob")
      join_remote_member_at(port_a, room_id, bob)

      charlie = remote_user_at(port_b, "charlie")
      join_remote_member_at(port_b, room_id, charlie)

      make_leave_conn =
        signed_get_at(
          port_b,
          "/_matrix/federation/v1/make_leave/#{URI.encode(room_id)}/#{URI.encode(charlie)}"
        )

      template = decode(make_leave_conn)["event"]

      leave_event =
        signed_remote_event_at(
          port_b,
          Map.merge(template, %{
            "event_id" => "$relayleave_#{System.unique_integer([:positive])}",
            "origin_server_ts" => System.os_time(:millisecond)
          })
        )

      path =
        "/_matrix/federation/v2/send_leave/#{URI.encode(room_id)}/#{URI.encode(leave_event["event_id"])}"

      conn = signed_put_at(port_b, path, leave_event)
      assert conn.status == 200

      wait_until(System.monotonic_time(:millisecond) + 5_000, fn ->
        Enum.any?(FakeRemoteMatrixServer.requests(port_a), fn req ->
          req.method == "PUT" and req.path =~ "/_matrix/federation/v1/send/" and
            pdus_contain_event_id?(req.body, leave_event["event_id"])
        end)
      end)
    end

    test "a knock via send_knock is relayed to the room's other resident server", %{
      port_a: port_a,
      port_b: port_b
    } do
      owner = new_local_user("owner")

      {:ok, room_id} =
        CreateRoom.execute(owner,
          server_name: "localhost",
          initial_state: [
            %{"type" => "m.room.join_rules", "content" => %{"join_rule" => "knock"}}
          ]
        )

      # The room only allows knocking, not a free join — bob needs an
      # invite first (an invited member can always join regardless of
      # join_rule).
      bob = remote_user_at(port_a, "bob")

      {:ok, _} =
        RoomProcess.send_event(room_id, owner, "m.room.member", %{"membership" => "invite"},
          state_key: bob
        )

      join_remote_member_at(port_a, room_id, bob)

      charlie = remote_user_at(port_b, "charlie")

      make_knock_conn =
        signed_get_at(
          port_b,
          "/_matrix/federation/v1/make_knock/#{URI.encode(room_id)}/#{URI.encode(charlie)}"
        )

      template = decode(make_knock_conn)["event"]

      knock_event =
        signed_remote_event_at(
          port_b,
          Map.merge(template, %{
            "event_id" => "$relayknock_#{System.unique_integer([:positive])}",
            "origin_server_ts" => System.os_time(:millisecond)
          })
        )

      path =
        "/_matrix/federation/v1/send_knock/#{URI.encode(room_id)}/#{URI.encode(knock_event["event_id"])}"

      conn = signed_put_at(port_b, path, knock_event)
      assert conn.status == 200

      wait_until(System.monotonic_time(:millisecond) + 5_000, fn ->
        Enum.any?(FakeRemoteMatrixServer.requests(port_a), fn req ->
          req.method == "PUT" and req.path =~ "/_matrix/federation/v1/send/" and
            pdus_contain_event_id?(req.body, knock_event["event_id"])
        end)
      end)
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

    # Regression: /_matrix/key/v2/query used to be routed through
    # AxonWeb.Plug.FederationAuth (X-Matrix signature required), same as
    # ordinary federation endpoints. Per spec it must be reachable with NO
    # authentication at all — exactly like /_matrix/key/v2/server — because
    # a server calls it precisely when it doesn't yet have (or can't yet
    # trust) the origin's key, so requiring a verifiable signature to reach
    # it is a chicken-and-egg deadlock. gomatrixserverlib's DirectKeyFetcher
    # falls back to this endpoint whenever a direct /v2/server fetch fails
    # its checks; with the old routing that fallback got a silent 401 (never
    # even reaching FederationAuth's own rejection logging, since an
    # unauthenticated caller is that plug's "missing header" branch, which
    # doesn't log), which is exactly the failure mode that broke
    # TestJoinViaRoomIDAndServerName end-to-end.
    test "requires no authentication at all — no Authorization header is sent" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/_matrix/key/v2/query", Jason.encode!(%{}))

      assert conn.status == 200
      [server_key] = decode(conn)["server_keys"]
      assert server_key["server_name"] == "localhost"
    end

    test "GET /_matrix/key/v2/query/:server_name/:key_id also requires no authentication" do
      conn = build_conn() |> get("/_matrix/key/v2/query/some-server.example/ed25519:abc")
      assert conn.status == 200
    end
  end
end
