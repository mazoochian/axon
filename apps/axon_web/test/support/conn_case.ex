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
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.checkin(AxonCore.Repo) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
