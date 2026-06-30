defmodule AxonCore.Repo.Migrations.CreateUsersAndAuth do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :user_id, :text, primary_key: true
      add :localpart, :text, null: false
      add :password_hash, :text
      add :deactivated, :boolean, null: false, default: false
      add :admin, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:localpart])

    create table(:user_profiles, primary_key: false) do
      add :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        primary_key: true

      add :displayname, :text
      add :avatar_url, :text

      timestamps(type: :utc_datetime_usec)
    end

    create table(:devices, primary_key: false) do
      add :device_id, :text, null: false
      add :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        null: false

      add :display_name, :text
      add :last_seen_ts, :bigint
      add :last_seen_ip, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:devices, [:user_id, :device_id])

    create table(:access_tokens) do
      add :token_hash, :text, null: false
      add :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        null: false

      add :device_id, :text, null: false
      add :valid, :boolean, null: false, default: true
      add :last_validated, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:access_tokens, [:token_hash])
    create index(:access_tokens, [:user_id, :device_id])

    create table(:refresh_tokens) do
      add :token_hash, :text, null: false
      add :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        null: false

      add :device_id, :text, null: false
      add :next_token_id, :bigint
      add :expiry_ts, :bigint
      add :ultimate_session_expiry_ts, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:refresh_tokens, [:token_hash])
  end
end
