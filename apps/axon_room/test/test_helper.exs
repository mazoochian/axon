# AxonCrypto.KeyServer is normally started by AxonWeb.Application — axon_room
# doesn't (and shouldn't) depend on axon_web, but AxonRoom.EventBuilder signs
# every event via KeyServer, so axon_room's own test suite must bootstrap it.
# When the whole umbrella's `mix test` runs from the repo root, axon_web's
# application is already started first and this is already running —
# tolerate that instead of crashing.
case AxonCrypto.KeyServer.start_link(server_name: "localhost") do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AxonCore.Repo, :manual)
