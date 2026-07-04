defmodule AxonCore.Repo.Migrations.AddKeyBackupVersionSequence do
  use Ecto.Migration

  def up do
    execute "CREATE SEQUENCE room_key_backup_version_seq"

    execute """
    SELECT setval('room_key_backup_version_seq', COALESCE((SELECT MAX(version::bigint) FROM room_key_backup_versions), 0) + 1, false)
    """
  end

  def down do
    execute "DROP SEQUENCE room_key_backup_version_seq"
  end
end
