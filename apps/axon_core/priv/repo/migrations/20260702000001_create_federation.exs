defmodule AxonCore.Repo.Migrations.CreateFederation do
  use Ecto.Migration

  def change do
    # Inbound federation transaction deduplication
    create table(:federation_inbound_txns, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :origin, :text, null: false
      add :txn_id, :text, null: false
      add :processed_at, :utc_datetime_usec, null: false
    end

    create unique_index(:federation_inbound_txns, [:origin, :txn_id])

    # Remote server key cache (persisted across restarts)
    create table(:remote_server_keys, primary_key: false) do
      add :server_name, :text, null: false
      add :key_id, :text, null: false
      add :public_key, :binary, null: false
      add :valid_until_ts, :bigint
      add :fetched_at, :utc_datetime_usec, default: fragment("now()")
    end

    create unique_index(:remote_server_keys, [:server_name, :key_id])
  end
end
