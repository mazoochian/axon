defmodule AxonSync.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Axon.PubSub},
      AxonSync.Manager,
      AxonSync.Presence
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AxonSync.Supervisor)
  end
end
