# AxonCrypto.KeyServer and the Axon.Finch pool are normally started by
# AxonWeb.Application's supervision tree — axon_federation doesn't (and
# shouldn't) depend on axon_web, so its own test suite must bootstrap the
# singletons its outbound HTTP/signing code (HttpClient, KeyCache, RoomJoin,
# RoomKnock) needs. When the whole umbrella's `mix test` runs from the repo
# root, axon_web's application is already started first and these are
# already running — tolerate that instead of crashing.
case Finch.start_link(name: Axon.Finch) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

case AxonCrypto.KeyServer.start_link(server_name: "localhost") do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AxonCore.Repo, :manual)
