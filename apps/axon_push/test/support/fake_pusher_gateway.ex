defmodule AxonPush.FakePusherGateway do
  @moduledoc """
  A tiny fake HTTP push gateway (Sygnal-shaped) for testing
  `AxonPush.Dispatcher`'s real outbound HTTP delivery, mirroring
  `AxonWeb.FakeOidcServer`'s Plug.Router + Bandit pattern.
  """

  use Plug.Router
  use Agent

  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
  plug :match
  plug :dispatch

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

    Supervisor.start_link(
      [
        %{id: agent_name(port), start: {Agent, :start_link, [fn -> [] end, [name: agent_name(port)]]}},
        %{id: {:bandit, port}, start: {Bandit, :start_link, [[plug: __MODULE__, ip: {127, 0, 0, 1}, port: port]]}}
      ],
      strategy: :one_for_all,
      name: :"#{inspect(__MODULE__)}.Supervisor#{port}"
    )
  end

  defp agent_name(port), do: :"axon_push_fake_gateway_#{port}"

  @doc "All notification payloads received so far, oldest first."
  def received(port), do: Agent.get(agent_name(port), &Enum.reverse/1)

  post "/_matrix/push/v1/notify" do
    Agent.update(agent_name(conn.port), fn reqs -> [conn.body_params | reqs] end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"rejected" => []}))
  end

  match _ do
    Plug.Conn.send_resp(conn, 404, "not found")
  end
end
