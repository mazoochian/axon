defmodule AxonCore.Repo.Migrations.Phase3E2EESsync do
  use Ecto.Migration

  def change do
    # Track when any user uploads new device or cross-signing keys.
    # Used by /sync device_lists.changed and /keys/changes.
    # stream_ordering is taken from the room event sequence at upload time
    # so it can be compared directly against the sync `since` token.
    create table(:device_list_updates) do
      add :user_id, :text, null: false
      add :stream_ordering, :bigint, null: false
    end

    create index(:device_list_updates, [:stream_ordering])
    create index(:device_list_updates, [:user_id, :stream_ordering])
  end
end
