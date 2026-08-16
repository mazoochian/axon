defmodule AxonWeb.FakeSmtpServer do
  @moduledoc """
  A tiny fake SMTP server, built directly on `:gen_smtp_server_session`
  (gen_smtp's own bundled session behaviour), for testing
  `AxonWeb.Mailer`'s real outbound SMTP delivery — mirroring
  `AxonPush.FakePusherGateway`'s Agent + Supervisor pattern, just for
  SMTP instead of HTTP.

  Accepts any HELO/EHLO/MAIL FROM/RCPT TO and records the raw message
  of every completed DATA transaction, keyed by port, so tests assert
  on what `:gen_smtp_client` actually put on the wire instead of mocking
  the client.
  """

  @behaviour :gen_smtp_server_session

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
        %{
          id: agent_name(port),
          start: {Agent, :start_link, [fn -> [] end, [name: agent_name(port)]]}
        },
        :gen_smtp_server.child_spec(server_name(port), __MODULE__, [
          {:port, port},
          {:address, {127, 0, 0, 1}},
          {:sessionoptions, [{:callbackoptions, [port: port]}]}
        ])
      ],
      strategy: :one_for_all,
      name: :"#{inspect(__MODULE__)}.Supervisor#{port}"
    )
  end

  defp agent_name(port), do: :"axon_web_fake_smtp_#{port}"
  defp server_name(port), do: :"axon_web_fake_smtp_listener_#{port}"

  @doc "All completed messages received so far, oldest first: `%{from:, to:, data:}`."
  def received(port), do: Agent.get(agent_name(port), &Enum.reverse/1)

  # :gen_smtp_server_session callbacks — accept everything, record DATA.

  @impl true
  def init(_hostname, _session_count, _address, options) do
    port = Keyword.fetch!(options, :port)
    {:ok, "AxonWeb.FakeSmtpServer ESMTP", %{port: port}}
  end

  @impl true
  def handle_HELO(_hostname, state), do: {:ok, 655_360, state}

  @impl true
  def handle_EHLO(_hostname, extensions, state), do: {:ok, extensions, state}

  @impl true
  def handle_MAIL(_from, state), do: {:ok, state}

  @impl true
  def handle_MAIL_extension(_extension, state), do: {:ok, state}

  @impl true
  def handle_RCPT(_to, state), do: {:ok, state}

  @impl true
  def handle_RCPT_extension(_extension, state), do: {:ok, state}

  @impl true
  def handle_DATA(from, to, data, %{port: port} = state) do
    Agent.update(agent_name(port), fn msgs -> [%{from: from, to: to, data: data} | msgs] end)
    {:ok, "message accepted", state}
  end

  @impl true
  def handle_RSET(state), do: state

  @impl true
  def handle_VRFY(_address, state), do: {:error, "252 VRFY disabled", state}

  @impl true
  def handle_other(verb, _args, state), do: {["500 unrecognized: ", verb], state}

  @impl true
  def handle_AUTH(_type, _username, _password, _state), do: :error

  @impl true
  def handle_STARTTLS(state), do: state

  @impl true
  def handle_info(_info, state), do: {:noreply, state}

  @impl true
  def handle_error(_class, _details, state), do: {:ok, state}

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  @impl true
  def terminate(reason, state), do: {:ok, reason, state}
end
