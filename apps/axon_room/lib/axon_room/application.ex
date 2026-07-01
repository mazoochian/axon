defmodule AxonRoom.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Horde.Registry,
       [
         name: AxonRoom.Registry,
         keys: :unique,
         members: :auto
       ]},
      {Horde.DynamicSupervisor,
       [
         name: AxonRoom.Supervisor,
         strategy: :one_for_one,
         members: :auto
       ]},
      {Task.Supervisor, name: AxonRoom.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AxonRoom.Supervisor.Root)
  end
end
