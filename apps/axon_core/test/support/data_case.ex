defmodule AxonCore.DataCase do
  @moduledoc """
  Sets up an Ecto sandbox connection for tests that exercise `AxonCore`'s
  business logic (`EventStore`, `UserStore`, `KeyStore`, schemas) directly
  against Postgres, with no HTTP layer involved.
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
