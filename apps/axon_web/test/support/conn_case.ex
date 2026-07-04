defmodule AxonWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      @endpoint AxonWeb.Endpoint

      import AxonWeb.ConnCase

      def json_post(conn, path, body) do
        conn
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(body))
      end

      def json_put(conn, path, body) do
        conn
        |> put_req_header("content-type", "application/json")
        |> put(path, Jason.encode!(body))
      end

      def authed_conn(token) do
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
      end
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AxonCore.Repo)
    # Shared mode lets GenServer processes (RoomProcess, etc.) use the same connection.
    Ecto.Adapters.SQL.Sandbox.mode(AxonCore.Repo, {:shared, self()})

    on_exit(fn ->
      # Controllers dispatch some work fire-and-forget (AxonWeb.ProfileController's
      # profile propagation, AxonPush.Dispatcher) via Task.Supervisor children that
      # share this test's sandboxed connection — and dispatch can itself spawn
      # further children (e.g. profile propagation triggers a room event, which
      # triggers a push-dispatch task). If the connection is checked in while one
      # is still mid-query, it dies with a DBConnection "owner exited" error. Wait
      # for the supervisors to go quiet (fixed-point, since children can nest)
      # before checking in.
      AxonWeb.ConnCase.await_task_supervisors_idle(
        [Axon.TaskSupervisor, AxonPush.TaskSupervisor],
        System.monotonic_time(:millisecond) + 5_000
      )

      Ecto.Adapters.SQL.Sandbox.checkin(AxonCore.Repo)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc false
  def await_task_supervisors_idle(supervisors, deadline_ms) do
    children = Enum.flat_map(supervisors, &Task.Supervisor.children/1)

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

        await_task_supervisors_idle(supervisors, deadline_ms)
    end
  end
end
