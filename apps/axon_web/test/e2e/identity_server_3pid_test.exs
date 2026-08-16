defmodule AxonWeb.E2E.IdentityServer3pidTest do
  @moduledoc """
  Real, non-mocked end-to-end coverage against the actual Sydent
  container (matrix.org's reference identity server) — not a fake. Every
  other 3pid-invite test (`apps/axon_web/test/third_party_invite_test.exs`)
  uses `AxonWeb.FakeIdentityServer` for edge cases; this file exists
  specifically to prove the real spec flow works against real identity
  server code: invite an unbound email 3pid -> real `store-invite` on
  Sydent -> the invitee proves ownership through Sydent's own real
  requestToken/submitToken/bind flow -> join with the proof *that* flow
  produces -> membership succeeds.

  Requires, all documented in README.md's "Identity server (3pid
  invites)" section:

    * The dev Sydent container running:
      `docker compose -f docker-compose.identity.yml up -d`
      (`network_mode: host`, so it shares the test host's loopback).
    * Sydent's one-time `sydent.conf` patches (no env-var equivalent
      exists for these): `ip.whitelist` including loopback (Sydent
      blocks federation-agent connections to 127.0.0.1/::1 by default —
      SSRF hardening — which would otherwise block its callback to
      axon below), `federation.verifycerts = False` (axon's federation
      endpoint below serves a self-signed cert), `templates.path`
      pointed at the image's actual `res/` location, and
      `email.smtpport = 2525` (this test's own `AxonWeb.FakeSmtpServer`
      instance — Sydent's default `localhost:25` needs root and isn't
      running here).

  This test itself, for its own duration, additionally starts:

    * A *real* TCP/TLS listener for `AxonWeb.FederationEndpoint` on port
      8448 (self-signed cert, `test/support/fixtures/`) — config/test.exs
      sets `server: false` so nothing normally listens there; Sydent's
      real `POST account/register` needs to actually reach
      `GET /_matrix/federation/v1/openid/userinfo` on this homeserver to
      verify the OpenID token `AxonWeb.IdentityServer.ensure_access_token/2`
      mints (see `AxonWeb.OpenidTokens`), for the DEFAULT_IDENTITY_SERVER
      self-registration path this test exercises.
    * `AxonWeb.FakeSmtpServer` on port 2525 — Sydent's own store-invite
      and validate/email/requestToken calls both send real mail through
      it (real SMTP protocol, real Sydent template rendering); this test
      parses the real validation code out of the captured message the
      same way a human reading their inbox would.

  Skips (doesn't fail) when Sydent isn't reachable, so the rest of the
  suite stays green without it running.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonWeb.FakeSmtpServer

  @sydent_url "http://localhost:8090"
  @fed_port 8448
  @smtp_port 2525
  @cert Path.join([__DIR__, "..", "support", "fixtures", "e2e_federation_cert.pem"])
  @key Path.join([__DIR__, "..", "support", "fixtures", "e2e_federation_key.pem"])

  setup_all do
    case Finch.build(:get, @sydent_url <> "/_matrix/identity/v2") |> Finch.request(Axon.Finch) do
      {:ok, %{status: 200}} ->
        :ok

      other ->
        {:skip,
         "real Sydent not reachable at #{@sydent_url} (#{inspect(other)}) — see docker-compose.identity.yml and README.md's \"Identity server (3pid invites)\""}
    end
  end

  setup do
    previous = Application.get_env(:axon_web, :default_identity_server)
    Application.put_env(:axon_web, :default_identity_server, @sydent_url)

    on_exit(fn ->
      if previous do
        Application.put_env(:axon_web, :default_identity_server, previous)
      else
        Application.delete_env(:axon_web, :default_identity_server)
      end
    end)

    start_supervised!({FakeSmtpServer, port: @smtp_port})

    start_supervised!(%{
      id: :e2e_federation_listener,
      start:
        {Bandit, :start_link,
         [[plug: AxonWeb.FederationEndpoint, scheme: :https, ip: {0, 0, 0, 0}, port: @fed_port, certfile: @cert, keyfile: @key]]}
    })

    :ok
  end

  test "invite unbound email 3pid -> real Sydent store-invite -> join with Sydent's own signed proof succeeds" do
    unique = System.unique_integer([:positive])
    alice = register("sydent_e2e_alice_#{unique}")
    bob_mxid = "@sydent_e2e_bob_#{unique}:localhost"
    bob_email = "sydent_e2e_bob_#{unique}@example.com"
    client_secret = "e2e_client_secret_#{unique}"

    room_id = create_room(alice.token, %{"preset" => "private_chat"})

    # 1. Real delegated invite — axon self-registers with Sydent via the
    #    real OpenID round trip (DEFAULT_IDENTITY_SERVER, no client
    #    id_access_token given), then does a real hash lookup (unbound —
    #    nothing has bound bob_email yet) and a real store-invite.
    invite_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/invite", %{"medium" => "email", "address" => bob_email})

    assert invite_conn.status == 200

    sync_conn = authed(alice.token) |> get("/_matrix/client/v3/sync")
    room_state = get_in(decode(sync_conn), ["rooms", "join", room_id, "state", "events"])
    invite_event = Enum.find(room_state, &(&1["type"] == "m.room.third_party_invite"))

    assert invite_event
    token = invite_event["state_key"]

    # It's Sydent's own real long-term key, not axon's.
    refute invite_event["content"]["public_key"] == AxonCrypto.KeyServer.server_key_info().public_key_b64
    assert [_long_term, _ephemeral] = invite_event["content"]["public_keys"]

    assert Enum.all?(invite_event["content"]["public_keys"], fn %{"key_validity_url" => url} ->
             String.starts_with?(url, @sydent_url)
           end)

    # 2. Bob (the invitee) independently proves ownership of bob_email to
    #    the *same* real Sydent instance — the real validate/email
    #    requestToken -> (real mail, captured by FakeSmtpServer) ->
    #    submitToken -> bind flow, exactly as a real client would drive
    #    it. v1 (unauthenticated) endpoints, matching what a client with
    #    no id_access_token of its own yet would actually call.
    request_body =
      Jason.encode!(%{"client_secret" => client_secret, "email" => bob_email, "send_attempt" => 1})

    {:ok, request_resp} =
      Finch.build(:post, @sydent_url <> "/_matrix/identity/api/v1/validate/email/requestToken", [
        {"content-type", "application/json"}
      ], request_body)
      |> Finch.request(Axon.Finch)

    %{"sid" => sid} = Jason.decode!(request_resp.body)

    validation_code = wait_for_validation_code(bob_email)

    submit_body = Jason.encode!(%{"sid" => sid, "client_secret" => client_secret, "token" => validation_code})

    {:ok, submit_resp} =
      Finch.build(:post, @sydent_url <> "/_matrix/identity/api/v1/validate/email/submitToken", [
        {"content-type", "application/json"}
      ], submit_body)
      |> Finch.request(Axon.Finch)

    assert %{"success" => true} = Jason.decode!(submit_resp.body)

    bind_body = Jason.encode!(%{"sid" => sid, "client_secret" => client_secret, "mxid" => bob_mxid})

    {:ok, bind_resp} =
      Finch.build(:post, @sydent_url <> "/_matrix/identity/api/v1/3pid/bind", [{"content-type", "application/json"}], bind_body)
      |> Finch.request(Axon.Finch)

    bind_data = Jason.decode!(bind_resp.body)
    invite = Enum.find(bind_data["invites"], &(&1["token"] == token))
    assert invite, "Sydent's real bind response didn't include a signed proof for this invite's token"
    proof = invite["signed"]
    assert proof["mxid"] == bob_mxid
    assert proof["signatures"]

    # 3. Bob registers on axon for real and joins using Sydent's own
    #    real signed proof — AuthRules.valid_third_party_invite?/3
    #    verifies it against the identity server's real long-term key
    #    stored in the room's own m.room.third_party_invite content, not
    #    any axon-side assumption.
    bob = register(bob_mxid |> String.trim_leading("@") |> String.trim_trailing(":localhost"))
    assert bob.user_id == bob_mxid

    join_conn =
      authed(bob.token)
      |> jp("/_matrix/client/v3/join/#{room_id}", %{"third_party_signed" => proof})

    assert join_conn.status == 200

    members_conn = authed(alice.token) |> get("/_matrix/client/v3/rooms/#{room_id}/joined_members")
    assert Map.has_key?(decode(members_conn)["joined"], bob_mxid)
  end

  # Sydent sends two real emails for a fresh invite + requestToken pair
  # (the "you've been invited" notice from store-invite, and the
  # validation code itself) — polls briefly since delivery is async on
  # Sydent's side, and picks the one actually containing a code rather
  # than assuming ordering.
  defp wait_for_validation_code(_email, attempts_left \\ 20)

  defp wait_for_validation_code(email, 0), do: flunk("no validation email arrived for #{email} within the timeout")

  defp wait_for_validation_code(email, attempts_left) do
    case Enum.find(FakeSmtpServer.received(@smtp_port), &String.contains?(&1.data, "code is")) do
      nil ->
        Process.sleep(250)
        wait_for_validation_code(email, attempts_left - 1)

      msg ->
        [[_, code] | _] = Regex.scan(~r/code is (\S+)/, msg.data)
        code
    end
  end
end
