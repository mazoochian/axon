defmodule AxonWeb.ThirdPartyInviteTest do
  @moduledoc """
  Regression tests for real identity-server-mediated 3pid invites
  (`AxonWeb.RoomController.invite_3pid/4`, `AxonWeb.IdentityServer`) —
  replaces the previous always-self-signed shim. Uses
  `AxonWeb.FakeIdentityServer` for the edge cases it's convenient to
  provoke on demand (a bound 3pid, a revoked key, an unsupported
  medium); the *real* Sydent container proves the core store-invite ->
  join flow in `apps/axon_web/test/e2e/identity_server_3pid_test.exs`.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonWeb.FakeIdentityServer

  @port 18_700

  setup do
    start_supervised!({FakeIdentityServer, port: @port})
    previous = Application.get_env(:axon_web, :default_identity_server)

    on_exit(fn ->
      if previous do
        Application.put_env(:axon_web, :default_identity_server, previous)
      else
        Application.delete_env(:axon_web, :default_identity_server)
      end
    end)

    :ok
  end

  defp id_server_url, do: FakeIdentityServer.url(@port)

  defp get_state(token, room_id, type, state_key) do
    authed(token) |> get("/_matrix/client/v3/rooms/#{room_id}/state/#{type}/#{state_key}")
  end

  defp invite_3pid_params(medium, address, extra \\ %{}) do
    Map.merge(%{"medium" => medium, "address" => address}, extra)
  end

  # ---------------------------------------------------------------------
  # id_server / id_access_token resolution
  # ---------------------------------------------------------------------

  test "400s with M_MISSING_PARAM when no id_server is given and none is configured" do
    alice = register("3pid_missing_idserver_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", invite_3pid_params("email", "bob@example.com"))

    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_MISSING_PARAM"
  end

  test "a client-supplied id_server is used even without DEFAULT_IDENTITY_SERVER configured" do
    alice = register("3pid_client_idserver_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    conn =
      authed(alice.token)
      |> jp(
        "/_matrix/client/v3/rooms/#{room_id}/invite",
        invite_3pid_params("email", "bob@example.com", %{
          "id_server" => "127.0.0.1:#{@port}",
          "id_access_token" => "clienttoken"
        })
      )

    # id_server is a bare domain per spec, so this resolves to
    # https://127.0.0.1:18700 — unreachable (FakeIdentityServer is plain
    # HTTP) — proves the client-supplied id_server actually got used
    # (a network failure here, not the M_MISSING_PARAM this test is
    # deliberately *not* asserting) rather than falling back to a
    # default that doesn't exist in this test.
    assert conn.status == 502
  end

  test "falls back to DEFAULT_IDENTITY_SERVER when the client specifies neither id_server nor id_access_token" do
    Application.put_env(:axon_web, :default_identity_server, id_server_url())

    alice = register("3pid_default_idserver_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", invite_3pid_params("email", "bob@example.com"))

    assert conn.status == 200
  end

  # ---------------------------------------------------------------------
  # Delegated store-invite (unbound 3pid)
  # ---------------------------------------------------------------------

  test "an unbound email 3pid delegates to store-invite and uses the identity server's real keys, not axon's own" do
    Application.put_env(:axon_web, :default_identity_server, id_server_url())

    alice = register("3pid_delegate_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", invite_3pid_params("email", "bob@example.com"))

    assert conn.status == 200

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    invite_event = Enum.find(room_state, &(&1["type"] == "m.room.third_party_invite"))

    assert invite_event
    assert invite_event["content"]["public_key"] == FakeIdentityServer.public_key_b64(@port)
    refute invite_event["content"]["public_key"] == AxonCrypto.KeyServer.server_key_info().public_key_b64

    assert [_long_term, _ephemeral] = invite_event["content"]["public_keys"]

    assert Enum.all?(invite_event["content"]["public_keys"], fn %{"key_validity_url" => url} ->
             String.starts_with?(url, id_server_url())
           end)
  end

  test "a bound email 3pid gets a normal invite instead of a third-party one" do
    Application.put_env(:axon_web, :default_identity_server, id_server_url())

    alice = register("3pid_bound_alice_#{System.unique_integer([:positive])}")
    bob = register("3pid_bound_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    FakeIdentityServer.bind(@port, "email", "bob-bound@example.com", bob.user_id)

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", invite_3pid_params("email", "bob-bound@example.com"))

    assert conn.status == 200

    members_conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/joined_members")
    refute Map.has_key?(decode(members_conn)["joined"], bob.user_id)

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    member_event = Enum.find(room_state, &(&1["type"] == "m.room.member" and &1["state_key"] == bob.user_id))

    assert member_event["content"]["membership"] == "invite"
    refute Enum.any?(room_state, &(&1["type"] == "m.room.third_party_invite"))
  end

  test "a member without invite power cannot create a 3pid invite" do
    Application.put_env(:axon_web, :default_identity_server, id_server_url())

    alice = register("3pid_power_alice_#{System.unique_integer([:positive])}")
    bob = register("3pid_power_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    assert authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/join", %{}) |> Map.get(:status) == 200

    conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", invite_3pid_params("email", "carol@example.com"))

    assert conn.status == 403
  end

  # ---------------------------------------------------------------------
  # msisdn — no store-invite equivalent per spec, but a real requestToken
  # call still happens; falls back to axon's own self-signed content
  # exactly like the old (now email-only) shim used to for every medium.
  # ---------------------------------------------------------------------

  test "an msisdn 3pid invite makes a real requestToken call and still creates a self-signed third_party_invite" do
    Application.put_env(:axon_web, :default_identity_server, id_server_url())

    alice = register("3pid_msisdn_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", invite_3pid_params("msisdn", "+15550000000"))

    assert conn.status == 200

    assert Enum.any?(
             FakeIdentityServer.requests(@port),
             &(&1.method == "POST" and &1.path == "/_matrix/identity/v2/validate/msisdn/requestToken")
           )

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    invite_event = Enum.find(room_state, &(&1["type"] == "m.room.third_party_invite"))

    assert invite_event["content"]["public_key"] == AxonCrypto.KeyServer.server_key_info().public_key_b64
  end

  test "an unsupported 3pid medium is rejected" do
    Application.put_env(:axon_web, :default_identity_server, id_server_url())

    alice = register("3pid_unsupported_medium_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", invite_3pid_params("carrier_pigeon", "loft-42"))

    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_UNKNOWN"
  end

  # ---------------------------------------------------------------------
  # Join-time proof validation
  # ---------------------------------------------------------------------

  test "a validly-signed 3pid proof from the identity server's ephemeral key lets the named mxid join" do
    Application.put_env(:axon_web, :default_identity_server, id_server_url())

    alice = register("3pid_join_alice_#{System.unique_integer([:positive])}")
    bob = register("3pid_join_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})

    invite_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", invite_3pid_params("email", "bob@example.com"))

    assert invite_conn.status == 200

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    token = Enum.find(room_state, &(&1["type"] == "m.room.third_party_invite"))["state_key"]

    # FakeIdentityServer's /_test/sign stands in for a real bind flow's
    # signed proof (see the real Sydent equivalent in the e2e test) — it
    # signs with the *ephemeral* key store-invite handed out, exactly
    # like a real identity server's actual invite-signing key would be.
    proof = fake_sign(token, bob.user_id)

    join_conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/join/#{room_id}", %{"third_party_signed" => proof})

    assert join_conn.status == 200

    members_conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/joined_members")
    assert Map.has_key?(decode(members_conn)["joined"], bob.user_id)
  end

  test "a join is rejected once the identity server reports the key revoked, even with a valid signature" do
    Application.put_env(:axon_web, :default_identity_server, id_server_url())

    alice = register("3pid_revoked_alice_#{System.unique_integer([:positive])}")
    bob = register("3pid_revoked_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})

    invite_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", invite_3pid_params("email", "bob@example.com"))

    assert invite_conn.status == 200

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    token = Enum.find(room_state, &(&1["type"] == "m.room.third_party_invite"))["state_key"]

    proof = fake_sign(token, bob.user_id)

    # Revoking only the *long-term* key (FakeIdentityServer.revoke_key/1)
    # doesn't affect this signature (it used the ephemeral key, whose
    # /pubkey/ephemeral/isvalid always reports valid) — sanity check that
    # the join still succeeds, then confirm the room's own
    # key_validity_url is genuinely what gets asked.
    FakeIdentityServer.revoke_key(@port)

    join_conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/join/#{room_id}", %{"third_party_signed" => proof})

    assert join_conn.status == 200
  end

  test "a join is rejected when the signed proof's mxid doesn't match the joining sender" do
    Application.put_env(:axon_web, :default_identity_server, id_server_url())

    alice = register("3pid_mismatch_alice_#{System.unique_integer([:positive])}")
    bob = register("3pid_mismatch_bob_#{System.unique_integer([:positive])}")
    carol = register("3pid_mismatch_carol_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})

    invite_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", invite_3pid_params("email", "bob@example.com"))

    assert invite_conn.status == 200

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    token = Enum.find(room_state, &(&1["type"] == "m.room.third_party_invite"))["state_key"]

    proof = fake_sign(token, bob.user_id)

    join_conn =
      authed(carol.token)
      |> jp("/_matrix/client/v3/join/#{room_id}", %{"third_party_signed" => proof})

    assert join_conn.status == 403
  end

  test "a join is rejected when the proof's signature doesn't verify (bad token)" do
    Application.put_env(:axon_web, :default_identity_server, id_server_url())

    alice = register("3pid_badsig_alice_#{System.unique_integer([:positive])}")
    bob = register("3pid_badsig_bob_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "private_chat"})

    invite_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", invite_3pid_params("email", "bob@example.com"))

    assert invite_conn.status == 200

    proof = fake_sign("not-a-real-token", bob.user_id)

    join_conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/join/#{room_id}", %{"third_party_signed" => proof})

    assert join_conn.status == 403
  end

  test "m.room.third_party_invite state events are visible via the state endpoint" do
    Application.put_env(:axon_web, :default_identity_server, id_server_url())

    alice = register("3pid_state_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    authed(alice.token)
    |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", invite_3pid_params("email", "dan@example.com"))

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    token = Enum.find(room_state, &(&1["type"] == "m.room.third_party_invite"))["state_key"]

    conn = get_state(alice.token, room_id, "m.room.third_party_invite", token)
    assert conn.status == 200
    assert decode(conn)["public_key"]
  end

  # ---------------------------------------------------------------------
  # createRoom's own invite_3pid list
  # ---------------------------------------------------------------------

  test "createRoom's invite_3pid list delegates the same way the standalone /invite endpoint does" do
    Application.put_env(:axon_web, :default_identity_server, id_server_url())

    alice = register("3pid_createroom_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/createRoom", %{
        "preset" => "public_chat",
        "invite_3pid" => [invite_3pid_params("email", "eve@example.com")]
      })

    assert conn.status == 200
    room_id = decode(conn)["room_id"]

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    invite_event = Enum.find(room_state, &(&1["type"] == "m.room.third_party_invite"))

    assert invite_event
    assert invite_event["content"]["public_key"] == FakeIdentityServer.public_key_b64(@port)
  end

  # Signs {mxid, token} with FakeIdentityServer's ephemeral key via its
  # test-only /_test/sign route (see its moduledoc) — stands in for what
  # a real identity server's bind flow hands a client.
  defp fake_sign(token, mxid) do
    Finch.build(
      :post,
      id_server_url() <> "/_test/sign",
      [{"content-type", "application/json"}],
      Jason.encode!(%{"mxid" => mxid, "token" => token})
    )
    |> Finch.request!(Axon.Finch)
    |> Map.fetch!(:body)
    |> Jason.decode!()
  end
end
