defmodule AxonCore.Repo.Migrations.FixFallbackKeysAndAccountDataStream do
  use Ecto.Migration

  def change do
    # Existing fallback_keys rows stored the full "algorithm:key_id" string in the
    # algorithm column instead of just the algorithm name. All are invalid; clients
    # re-upload fallback keys on every sync so a full wipe is safe.
    execute("DELETE FROM fallback_keys", "SELECT 1")

    # Stream table for tracking account_data writes. Each PUT /account_data inserts
    # a row here so incremental syncs can return only the types that changed.
    create table(:account_data_stream) do
      add :user_id, :text, null: false
      add :type, :text, null: false
    end

    create index(:account_data_stream, [:user_id, :id])
  end
end
