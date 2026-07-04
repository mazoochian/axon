defmodule AxonCore.Repo.Migrations.AddE2eeUserFkCascades do
  use Ecto.Migration

  # Unlike room_memberships.user_id (see 20260704000001), these columns are
  # exclusively populated with the *local, authenticated* requester's own
  # user_id — never a remote federated user — so cascading on delete is safe:
  #
  #   - device_keys, one_time_keys, fallback_keys, cross_signing_keys,
  #     room_key_backup_versions, room_key_backups: always written with
  #     conn.assigns.current_user_id (see key_controller.ex).
  #   - cross_signing_signatures.signing_user_id: always the local signer
  #     (target_user_id is left alone — verifying a *remote* user's identity
  #     legitimately writes a foreign user_id there).
  #
  # Without this, deleting a `users` row (e.g. manual cleanup during
  # dev/test, or a future admin-purge feature) leaves orphaned E2EE rows
  # behind. If that user_id is later reused, the "new" account's very first
  # /keys/query returns the old account's stale, untrusted cross-signing
  # identity and device keys — which client-side crypto stacks correctly
  # treat as a corrupted identity and respond to by forcing a reset right
  # after registration.
  def up do
    for table <- ~w(device_keys one_time_keys fallback_keys cross_signing_keys
                     room_key_backup_versions room_key_backups) do
      execute("DELETE FROM #{table} WHERE user_id NOT IN (SELECT user_id FROM users)")
    end

    execute(
      "DELETE FROM cross_signing_signatures WHERE signing_user_id NOT IN (SELECT user_id FROM users)"
    )

    alter table(:device_keys) do
      modify :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        from: :text
    end

    alter table(:one_time_keys) do
      modify :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        from: :text
    end

    alter table(:fallback_keys) do
      modify :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        from: :text
    end

    alter table(:cross_signing_keys) do
      modify :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        from: :text
    end

    alter table(:cross_signing_signatures) do
      modify :signing_user_id,
             references(:users, column: :user_id, type: :text, on_delete: :delete_all),
             from: :text
    end

    alter table(:room_key_backup_versions) do
      modify :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        from: :text
    end

    alter table(:room_key_backups) do
      modify :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        from: :text
    end
  end

  def down do
    alter table(:device_keys) do
      modify :user_id, :text, from: references(:users, column: :user_id, type: :text)
    end

    alter table(:one_time_keys) do
      modify :user_id, :text, from: references(:users, column: :user_id, type: :text)
    end

    alter table(:fallback_keys) do
      modify :user_id, :text, from: references(:users, column: :user_id, type: :text)
    end

    alter table(:cross_signing_keys) do
      modify :user_id, :text, from: references(:users, column: :user_id, type: :text)
    end

    alter table(:cross_signing_signatures) do
      modify :signing_user_id, :text, from: references(:users, column: :user_id, type: :text)
    end

    alter table(:room_key_backup_versions) do
      modify :user_id, :text, from: references(:users, column: :user_id, type: :text)
    end

    alter table(:room_key_backups) do
      modify :user_id, :text, from: references(:users, column: :user_id, type: :text)
    end
  end
end
