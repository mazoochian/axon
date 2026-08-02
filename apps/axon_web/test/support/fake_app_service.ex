defmodule AxonWeb.FakeAppService do
  @moduledoc """
  A minimal in-process Application Service standing in for a real bridge in
  tests — mirrors `AxonFederation.FakeRemoteMatrixServer`'s pattern (a
  `Plug.Router` on a real loopback Bandit port, with a canned-response
  escape hatch and a request log) but for the three AS-facing endpoints
  axon calls out to: `PUT .../transactions/:txnId`, `GET .../users/:userId`,
  `GET .../rooms/:roomAlias`.

  Usage:

      port = 18_950
      start_supervised!({AxonWeb.FakeAppService, port: port})
      AxonWeb.FakeAppService.user_query_response(port, "@_bridge_ghost:localhost", 200)
      registration = %{"id" => "b", "url" => "http://127.0.0.1:\#{port}", "hs_token" => "hs-tok", ...}
  """

  use Plug.Router

  plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

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
    initial_state = %{overrides: %{}, requests: []}

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

  defp agent_name(port), do: :"axon_web_fake_appservice_#{port}"
  defp state(port), do: Agent.get(agent_name(port), & &1)
  defp update_state(port, fun), do: Agent.update(agent_name(port), fun)

  @doc "All requests received so far: `%{method, path, headers, body}` maps, oldest first."
  def requests(port), do: Enum.reverse(state(port).requests)

  def clear_requests(port), do: update_state(port, fn s -> %{s | requests: []} end)

  @doc "Escape hatch: `path_matcher` is an exact path string or a `Regex`."
  def put_response(port, {method, path_matcher}, status, body) do
    method = String.upcase(to_string(method))
    update_state(port, fn s -> put_in(s.overrides[{method, path_matcher}], {status, body}) end)
  end

  @doc """
  Like `put_response/4`, but runs `fun.()` (for its side effect — e.g. a
  real bridge synchronously registering a ghost user before answering a
  provisioning query) before responding. Runs in the Bandit request
  process, which shares this test's sandboxed DB connection via
  `AxonWeb.ConnCase`'s `{:shared, self()}` mode.
  """
  def put_response_fn(port, {method, path_matcher}, status, body, fun) when is_function(fun, 0) do
    method = String.upcase(to_string(method))

    update_state(port, fn s ->
      put_in(s.overrides[{method, path_matcher}], {status, body, fun})
    end)
  end

  @doc "Convenience: canned status for `GET /_matrix/app/v1/users/:userId`."
  def user_query_response(port, user_id, status) do
    put_response(
      port,
      {"GET", "/_matrix/app/v1/users/#{encode_path_segment(user_id)}"},
      status,
      %{}
    )
  end

  @doc "Convenience: canned status for `GET /_matrix/app/v1/rooms/:roomAlias`."
  def room_query_response(port, room_alias, status) do
    put_response(
      port,
      {"GET", "/_matrix/app/v1/rooms/#{encode_path_segment(room_alias)}"},
      status,
      %{}
    )
  end

  @doc "Same escaping `AxonWeb.AppService.Client` uses when building these URLs — a room_alias starts with `#`, which plain `URI.encode/1` doesn't escape."
  def encode_path_segment(value), do: URI.encode(value, &(&1 not in [?#, ??]))

  @doc "Convenience: canned status for `PUT /_matrix/app/v1/transactions/:txnId` (matches any txn_id)."
  def transaction_response(port, status) do
    put_response(port, {"PUT", ~r{^/_matrix/app/v1/transactions/}}, status, %{})
  end

  match _ do
    log_request(conn)

    case find_override(conn) do
      {status, body, fun} ->
        fun.()
        send_json(conn, status, body)

      {status, body} ->
        send_json(conn, status, body)

      nil ->
        send_json(conn, 200, %{})
    end
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

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
