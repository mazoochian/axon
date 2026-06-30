defmodule AxonCore.Repo do
  use Ecto.Repo,
    otp_app: :axon_core,
    adapter: Ecto.Adapters.Postgres
end
