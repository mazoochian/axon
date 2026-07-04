defmodule AxonFederation.FakeRemoteMatrixServer do
  @moduledoc """
  A minimal in-process Matrix homeserver standing in for a real federation
  peer in tests — mirrors `AxonWeb.FakeOidcServer`'s pattern (a `Plug.Router`
  on a real loopback Bandit port) but for the server-server API.

  Backed by a real Ed25519 keypair (via `AxonCrypto.KeyServer.generate_keypair/0`,
  the same code production uses), so it self-signs its `/_matrix/key/v2/server`
  response and any PDUs it hands out exactly like a real server — axon's real
  verification code (`AxonFederation.KeyCache`, `AxonWeb.Plug.FederationAuth`)
  is genuinely exercised against it, not mocked away.

  Usage — outbound tests (axon calling out to "the remote"):

      port = 18_300
      start_supervised!({AxonFederation.FakeRemoteMatrixServer, port: port, server_name: "fake.test"})
      Application.put_env(:axon_federation, :server_overrides, %{"fake.test" => "http://127.0.0.1:\#{port}"})
      AxonFederation.FakeRemoteMatrixServer.make_join_response(port, room_id, user_id, "10")
      AxonFederation.FakeRemoteMatrixServer.send_join_response(port, [], [])
      AxonFederation.RoomJoin.join_via_federation(room_id, user_id, ["fake.test"])

  Usage — inbound tests (building a legitimately-signed request *to* axon):

      header = AxonFederation.FakeRemoteMatrixServer.sign_request(port, "PUT", "/_matrix/federation/v1/send/txn1", body)
      conn = build_conn() |> put_req_header("authorization", header) |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

  For inbound tests, axon must also be able to fetch this fake server's keys,
  so register the same `server_overrides` entry before making the request.
  """

  use Plug.Router

  alias AxonCrypto.{CanonicalJSON, EventHash, KeyServer}

  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
  plug :match
  plug :dispatch

  # ---------------------------------------------------------------------------
  # Supervision
  # ---------------------------------------------------------------------------

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
    server_name = Keyword.fetch!(opts, :server_name)

    {key_id, public_key, private_key} = KeyServer.generate_keypair()

    initial_state = %{
      server_name: server_name,
      key_id: key_id,
      public_key: public_key,
      private_key: private_key,
      valid_until_ts: System.os_time(:millisecond) + 86_400_000,
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

  defp agent_name(port), do: :"axon_federation_fake_remote_#{port}"

  defp state(port), do: Agent.get(agent_name(port), & &1)

  defp update_state(port, fun), do: Agent.update(agent_name(port), fun)

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  def server_name(port), do: state(port).server_name
  def key_id(port), do: state(port).key_id
  def public_key_b64(port), do: Base.encode64(state(port).public_key, padding: false)

  @doc "Signs an event map as this fake server, the same way `AxonCrypto.KeyServer.sign_event/1` does."
  def sign_event(port, event) when is_map(event) do
    s = state(port)
    EventHash.sign_event(event, s.server_name, s.key_id, s.private_key)
  end

  @doc """
  Builds a valid `X-Matrix` Authorization header value as this fake server,
  for constructing inbound-to-axon requests in `FederationAuth`/`FederationController` tests.
  """
  def sign_request(port, method, path, body \\ nil) do
    s = state(port)
    destination = Application.get_env(:axon_web, :server_name, "localhost")

    signable =
      %{"method" => method, "uri" => path, "origin" => s.server_name, "destination" => destination}
      |> maybe_add_content(body)
      |> CanonicalJSON.encode_to_binary()

    sig_bytes = :crypto.sign(:eddsa, :none, signable, [s.private_key, :ed25519])
    sig_b64 = Base.encode64(sig_bytes, padding: false)

    ~s(X-Matrix origin="#{s.server_name}",destination="#{destination}",key="#{s.key_id}",sig="#{sig_b64}")
  end

  defp maybe_add_content(map, nil), do: map
  defp maybe_add_content(map, body) when is_map(body), do: Map.put(map, "content", body)

  # ---------------------------------------------------------------------------
  # Canned responses (escape hatch — takes priority over the built-in routes
  # below, for injecting edge cases: malformed bodies, error statuses, etc.)
  # `path_matcher` is either an exact path string or a `Regex`.
  # ---------------------------------------------------------------------------

  def put_response(port, {method, path_matcher}, status, body) do
    method = String.upcase(to_string(method))
    update_state(port, fn s -> put_in(s.overrides[{method, path_matcher}], {status, body}) end)
  end

  @doc "All requests received so far: `%{method, path, headers, body}` maps, oldest first."
  def requests(port), do: Enum.reverse(state(port).requests)

  def clear_requests(port), do: update_state(port, fn s -> %{s | requests: []} end)

  # ---------------------------------------------------------------------------
  # Convenience: the handful of routes axon's outbound federation code
  # (RoomJoin/RoomKnock) actually calls.
  # ---------------------------------------------------------------------------

  def make_join_response(port, room_id, user_id, room_version, extra_content \\ %{}) do
    s = state(port)

    template = %{
      "type" => "m.room.member",
      "room_id" => room_id,
      "sender" => user_id,
      "state_key" => user_id,
      "content" => Map.merge(%{"membership" => "join"}, extra_content),
      "depth" => 1,
      "prev_events" => [],
      "auth_events" => [],
      "origin" => s.server_name
    }

    put_response(
      port,
      {"GET", ~r{^/_matrix/federation/v1/make_join/#{Regex.escape(URI.encode(room_id))}/#{Regex.escape(URI.encode(user_id))}}},
      200,
      %{"event" => template, "room_version" => room_version}
    )
  end

  def send_join_response(port, state_events, auth_chain) do
    put_response(
      port,
      {"PUT", ~r{^/_matrix/federation/v2/send_join/}},
      200,
      %{"state" => state_events, "auth_chain" => auth_chain}
    )
  end

  def make_knock_response(port, room_id, user_id, room_version) do
    s = state(port)

    template = %{
      "type" => "m.room.member",
      "room_id" => room_id,
      "sender" => user_id,
      "state_key" => user_id,
      "content" => %{"membership" => "knock"},
      "depth" => 1,
      "prev_events" => [],
      "auth_events" => [],
      "origin" => s.server_name
    }

    put_response(
      port,
      {"GET", ~r{^/_matrix/federation/v1/make_knock/#{Regex.escape(URI.encode(room_id))}/#{Regex.escape(URI.encode(user_id))}}},
      200,
      %{"event" => template, "room_version" => room_version}
    )
  end

  def send_knock_response(port, knock_room_state) do
    put_response(
      port,
      {"PUT", ~r{^/_matrix/federation/v1/send_knock/}},
      200,
      %{"knock_room_state" => knock_room_state}
    )
  end

  # ---------------------------------------------------------------------------
  # Router
  # ---------------------------------------------------------------------------

  match _ do
    log_request(conn)

    case find_override(conn) do
      {status, body} -> send_json(conn, status, body)
      nil -> handle_builtin(conn)
    end
  end

  defp handle_builtin(%{method: "GET", request_path: "/_matrix/key/v2/server"} = conn) do
    port = conn.port
    s = state(port)
    send_json(conn, 200, key_doc(s))
  end

  defp handle_builtin(conn) do
    send_json(conn, 404, %{"errcode" => "M_NOT_FOUND", "error" => "no canned response registered for this route"})
  end

  defp find_override(conn) do
    port = conn.port

    Enum.find_value(state(port).overrides, fn
      {{method, %Regex{} = re}, resp} ->
        if conn.method == method and Regex.match?(re, conn.request_path), do: resp

      {{method, path}, resp} when is_binary(path) ->
        if conn.method == method and conn.request_path == path, do: resp
    end)
  end

  defp log_request(conn) do
    port = conn.port

    entry = %{
      method: conn.method,
      path: conn.request_path,
      headers: conn.req_headers,
      body: conn.body_params
    }

    update_state(port, fn s -> %{s | requests: [entry | s.requests]} end)
  end

  defp key_doc(s) do
    public_key_b64 = Base.encode64(s.public_key, padding: false)

    unsigned_doc = %{
      "server_name" => s.server_name,
      "valid_until_ts" => s.valid_until_ts,
      "verify_keys" => %{s.key_id => %{"key" => public_key_b64}}
    }

    sig_bytes = :crypto.sign(:eddsa, :none, CanonicalJSON.encode_to_binary(unsigned_doc), [s.private_key, :ed25519])
    sig_b64 = Base.encode64(sig_bytes, padding: false)

    Map.merge(unsigned_doc, %{
      "old_verify_keys" => %{},
      "signatures" => %{s.server_name => %{s.key_id => sig_b64}}
    })
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
