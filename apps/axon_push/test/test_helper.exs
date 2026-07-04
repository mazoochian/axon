# Axon.Finch is normally started by AxonWeb.Application — axon_push doesn't
# (and shouldn't) depend on axon_web, but AxonPush.Dispatcher posts to pusher
# gateways via it, so axon_push's own test suite must bootstrap it. When the
# whole umbrella's `mix test` runs from the repo root, axon_web's application
# is already started first and this is already running — tolerate that
# instead of crashing.
case Finch.start_link(name: Axon.Finch) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AxonCore.Repo, :manual)
