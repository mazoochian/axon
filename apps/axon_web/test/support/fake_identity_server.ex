defmodule AxonWeb.FakeIdentityServer do
  @moduledoc """
  A minimal in-process identity server standing in for a real one — same
  `Plug.Router` + real loopback Bandit port pattern
  `AxonFederation.FakeRemoteMatrixServer` uses for federation peers, here
  for `AxonWeb.IdentityServer`'s edge cases that don't need (or shouldn't
  depend on) the real Sydent container: missing/malformed responses, an
  already-bound 3pid, a revoked pubkey, msisdn's requestToken-only path.

  For the *core* delegated-invite-then-join flow, prefer testing against
  the real Sydent container instead (see
  `apps/axon_web/test/e2e/identity_server_3pid_test.exs`) — this fake
  exists for cases a real identity server can't conveniently be made to
  produce on demand (a specific hash algorithm, a deliberately-revoked
  key, an HTTP 500), not as a substitute for the real one.

  Bound 3pids are hashed with a fixed test pepper using the real sha256
  algorithm axon's own `AxonWeb.IdentityServer.hash_lookup/4` uses, so
  the hashing round-trip itself is genuinely exercised, not stubbed.
  """

  use Plug.Router

  alias AxonCrypto.{CanonicalJSON, KeyServer}

  plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  @pepper "fake_test_pepper"

  def child_spec(opts) do
    port = Keyword.fetch!(opts, :port)

    %{
      id: {__MODULE__, port},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    {key_id, public_key, private_key} = KeyServer.generate_keypair()
    {_eph_key_id, eph_public_key, eph_private_key} = KeyServer.generate_keypair()

    initial_state = %{
      port: port,
      key_id: key_id,
      public_key: public_key,
      private_key: private_key,
      ephemeral_public_key: eph_public_key,
      ephemeral_private_key: eph_private_key,
      # medium/address => mxid, for hash lookup
      bindings: %{},
      # token => %{sender:, address:, medium:}
      invites: %{},
      # {public_key} => bool, defaults to true (present) unless set
      revoked_keys: MapSet.new(),
      overrides: %{},
      requests: []
    }

    Supervisor.start_link(
      [
        %{
          id: agent_name(port),
          start: {Agent, :start_link, [fn -> initial_state end, [name: agent_name(port)]]}
        },
        %{
          id: {:bandit, port},
          start: {Bandit, :start_link, [[plug: __MODULE__, ip: {127, 0, 0, 1}, port: port]]}
        }
      ],
      strategy: :one_for_all,
      name: :"#{inspect(__MODULE__)}.Supervisor#{port}"
    )
  end

  defp agent_name(port), do: :"axon_web_fake_identity_server_#{port}"
  defp state(port), do: Agent.get(agent_name(port), & &1)
  defp update_state(port, fun), do: Agent.update(agent_name(port), fun)

  @doc "Base URL for `port` — pass as DEFAULT_IDENTITY_SERVER / id_server."
  def url(port), do: "http://127.0.0.1:#{port}"

  @doc "Binds `medium`/`address` to `mxid`, so hash_lookup/4 finds it."
  def bind(port, medium, address, mxid) do
    update_state(port, fn s -> put_in(s.bindings[{medium, address}], mxid) end)
  end

  @doc "Marks the fake's long-term public key as revoked (pubkey/isvalid returns false)."
  def revoke_key(port), do: update_state(port, fn s -> %{s | revoked_keys: MapSet.put(s.revoked_keys, s.public_key)} end)

  def public_key_b64(port), do: Base.encode64(state(port).public_key, padding: false)
  def ephemeral_public_key_b64(port), do: Base.encode64(state(port).ephemeral_public_key, padding: false)

  @doc "Escape hatch for edge cases (500s, malformed bodies) — same shape as FakeRemoteMatrixServer.put_response/4."
  def put_response(port, {method, path_matcher}, status, body) do
    method = String.upcase(to_string(method))
    update_state(port, fn s -> put_in(s.overrides[{method, path_matcher}], {status, body}) end)
  end

  def requests(port), do: Enum.reverse(state(port).requests)

  # ---------------------------------------------------------------------
  # Router
  # ---------------------------------------------------------------------

  match _ do
    log_request(conn)

    case find_override(conn) do
      {status, body} -> send_json(conn, status, body)
      nil -> handle_builtin(conn)
    end
  end

  defp handle_builtin(%{method: "GET", request_path: "/_matrix/identity/v2/hash_details"} = conn) do
    send_json(conn, 200, %{"algorithms" => ["sha256", "none"], "lookup_pepper" => @pepper})
  end

  defp handle_builtin(%{method: "POST", request_path: "/_matrix/identity/v2/lookup"} = conn) do
    s = state(conn.port)
    addresses = conn.body_params["addresses"] || []

    mappings =
      s.bindings
      |> Enum.reduce(%{}, fn {{medium, address}, mxid}, acc ->
        hashed = :crypto.hash(:sha256, "#{address} #{medium} #{@pepper}") |> Base.url_encode64(padding: false)
        if hashed in addresses, do: Map.put(acc, hashed, mxid), else: acc
      end)

    send_json(conn, 200, %{"mappings" => mappings})
  end

  defp handle_builtin(%{method: "POST", request_path: "/_matrix/identity/v2/store-invite"} = conn) do
    s = state(conn.port)
    %{"medium" => medium, "address" => address, "sender" => sender} = conn.body_params
    token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    update_state(conn.port, fn st -> put_in(st.invites[token], %{sender: sender, address: address, medium: medium}) end)

    long_term_pk = Base.encode64(s.public_key, padding: false)
    eph_pk = Base.encode64(s.ephemeral_public_key, padding: false)
    base = url(conn.port)

    send_json(conn, 200, %{
      "token" => token,
      "display_name" => obfuscate(address),
      "public_keys" => [
        %{"public_key" => long_term_pk, "key_validity_url" => base <> "/_matrix/identity/v2/pubkey/isvalid"},
        %{
          "public_key" => eph_pk,
          "key_validity_url" => base <> "/_matrix/identity/v2/pubkey/ephemeral/isvalid"
        }
      ]
    })
  end

  defp handle_builtin(%{method: "POST", request_path: "/_matrix/identity/v2/validate/msisdn/requestToken"} = conn) do
    send_json(conn, 200, %{"sid" => "fake-msisdn-sid"})
  end

  defp handle_builtin(%{method: "GET", request_path: "/_matrix/identity/v2/pubkey/isvalid"} = conn) do
    s = state(conn.port)
    public_key_b64 = conn.query_params["public_key"]

    case Base.decode64(public_key_b64 || "", padding: false) do
      {:ok, bytes} -> send_json(conn, 200, %{"valid" => bytes not in s.revoked_keys})
      :error -> send_json(conn, 200, %{"valid" => false})
    end
  end

  defp handle_builtin(%{method: "GET", request_path: "/_matrix/identity/v2/pubkey/ephemeral/isvalid"} = conn) do
    send_json(conn, 200, %{"valid" => true})
  end

  defp handle_builtin(%{method: "POST", request_path: "/_matrix/identity/v2/account/register"} = conn) do
    send_json(conn, 200, %{"access_token" => "fake_id_access_token", "token" => "fake_id_access_token"})
  end

  # Test-only convenience beyond what a real identity server exposes:
  # signs {mxid, token} with this fake's *ephemeral* key, exactly the
  # shape a real bind flow (Sydent's ThreepidBinder.addBinding) hands
  # back — lets edge-case tests get a validly-signed proof without
  # driving a full requestToken/submitToken/bind round trip themselves.
  defp handle_builtin(%{method: "POST", request_path: "/_test/sign"} = conn) do
    s = state(conn.port)
    %{"mxid" => mxid, "token" => token} = conn.body_params

    signable = %{"mxid" => mxid, "token" => token} |> CanonicalJSON.encode_to_binary()
    sig_bytes = :crypto.sign(:eddsa, :none, signable, [s.ephemeral_private_key, :ed25519])
    sig_b64 = Base.encode64(sig_bytes, padding: false)

    send_json(conn, 200, %{
      "mxid" => mxid,
      "token" => token,
      "signatures" => %{"fake.identity.test" => %{s.key_id => sig_b64}}
    })
  end

  defp handle_builtin(conn) do
    send_json(conn, 404, %{"errcode" => "M_NOT_FOUND", "error" => "no route in FakeIdentityServer"})
  end

  defp obfuscate(address) do
    case String.split(address, "@", parts: 2) do
      [local, domain] -> String.slice(local, 0, 1) <> "..." <> "@" <> String.slice(domain, 0, 3) <> "..."
      _ -> "***"
    end
  end

  defp find_override(conn) do
    port = conn.port

    Enum.find_value(state(port).overrides, fn
      {{method, %Regex{} = re}, resp} -> if conn.method == method and Regex.match?(re, conn.request_path), do: resp
      {{method, path}, resp} when is_binary(path) -> if conn.method == method and conn.request_path == path, do: resp
    end)
  end

  defp log_request(conn) do
    port = conn.port
    entry = %{method: conn.method, path: conn.request_path, headers: conn.req_headers, body: conn.body_params}
    update_state(port, fn s -> %{s | requests: [entry | s.requests]} end)
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
