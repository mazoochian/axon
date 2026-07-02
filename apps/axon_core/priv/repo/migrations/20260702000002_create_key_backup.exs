defmodule AxonCore.Repo.Migrations.CreateKeyBackup do
  use Ecto.Migration

  def change do
    create table(:room_key_backup_versions, primary_key: false) do
      add :version, :text, null: false, primary_key: true
      add :algorithm, :text, null: false
      add :auth_data, :map, null: false
      add :etag, :text, null: false, default: "0"
      add :count, :bigint, null: false, default: 0
      add :deleted, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:room_key_backups, primary_key: false) do
      add :version, :text, null: false
      add :room_id, :text, null: false
      add :session_id, :text, null: false
      add :first_message_index, :integer
      add :forwarded_count, :integer, null: false, default: 0
      add :is_verified, :boolean, null: false, default: false
      add :session_data, :map, null: false
    end

    create unique_index(:room_key_backups, [:version, :room_id, :session_id])
  end
end
