defmodule AxonSync.DataCase do
  @moduledoc """
  Sets up an Ecto sandbox connection for tests that exercise `AxonSync.Manager`
  (which reads events via `AxonCore.EventStore`) directly against Postgres.
  Not needed for `AxonSync.Presence`, which is pure ETS.
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
    Ecto.Adapters.SQL.Sandbox.mode(AxonCore.Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.checkin(AxonCore.Repo) end)
    :ok
  end
end
