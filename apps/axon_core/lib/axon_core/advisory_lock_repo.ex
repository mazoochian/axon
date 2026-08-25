defmodule AxonCore.AdvisoryLockRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :axon_core, adapter: Ecto.Adapters.Postgres
end
