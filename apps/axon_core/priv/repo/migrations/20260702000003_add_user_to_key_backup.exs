defmodule AxonCore.Repo.Migrations.AddUserToKeyBackup do
  use Ecto.Migration

  def change do
    alter table(:room_key_backup_versions) do
      add :user_id, :text
    end

    create index(:room_key_backup_versions, [:user_id])

    alter table(:room_key_backups) do
      add :user_id, :text
    end

    create index(:room_key_backups, [:user_id, :version])
  end
end
