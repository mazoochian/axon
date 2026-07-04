defmodule AxonRoom.DataCase do
  @moduledoc """
  Sets up an Ecto sandbox connection for tests that exercise `AxonRoom`'s
  business logic (`AuthRules`, `StateResV2`, `RestrictedJoin`, `CreateRoom`,
  `RoomUpgrade`, `RoomProcess`) directly against Postgres.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      alias AxonCore.Repo
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AxonCore.Repo)
    # Shared mode lets RoomProcess (a separate GenServer, possibly spawning its
    # own fire-and-forget AxonPush.Dispatcher task on every event) share this
    # test's sandboxed connection.
    Ecto.Adapters.SQL.Sandbox.mode(AxonCore.Repo, {:shared, self()})

    on_exit(fn ->
      AxonRoom.DataCase.await_task_supervisor_idle(
        AxonPush.TaskSupervisor,
        System.monotonic_time(:millisecond) + 5_000
      )

      Ecto.Adapters.SQL.Sandbox.checkin(AxonCore.Repo)
    end)

    :ok
  end

  @doc false
  def await_task_supervisor_idle(supervisor, deadline_ms) do
    children = Task.Supervisor.children(supervisor)

    cond do
      children == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        :ok

      true ->
        Enum.each(children, fn pid ->
          ref = Process.monitor(pid)
          timeout = max(deadline_ms - System.monotonic_time(:millisecond), 0)

          receive do
            {:DOWN, ^ref, _, _, _} -> :ok
          after
            timeout -> Process.demonitor(ref, [:flush])
          end
        end)

        await_task_supervisor_idle(supervisor, deadline_ms)
    end
  end
end
