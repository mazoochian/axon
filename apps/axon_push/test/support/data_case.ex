defmodule AxonPush.DataCase do
  @moduledoc """
  Sets up an Ecto sandbox connection for tests that exercise `AxonPush`'s
  logic (`RuleEvaluator` reads `room_memberships`/`user_profiles`;
  `Dispatcher` reads `pushers`) directly against Postgres.
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
