defmodule AxonCore.Repo.Migrations.CreateSyncAndAccountData do
  use Ecto.Migration

  def change do
    # Per-user account data
    create table(:account_data, primary_key: false) do
      add :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        null: false

      add :type, :text, null: false
      add :content, :map, null: false
      add :stream_ordering, :bigserial
    end

    create unique_index(:account_data, [:user_id, :type])

    # Per-room per-user account data
    create table(:room_account_data, primary_key: false) do
      add :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        null: false

      add :room_id, references(:rooms, column: :room_id, type: :text), null: false
      add :type, :text, null: false
      add :content, :map, null: false
      add :stream_ordering, :bigserial
    end

    create unique_index(:room_account_data, [:user_id, :room_id, :type])

    # Read receipts (m.read, m.read.private)
    create table(:receipts, primary_key: false) do
      add :room_id, :text, null: false
      add :user_id, :text, null: false
      add :receipt_type, :text, null: false
      add :event_id, :text, null: false
      add :thread_id, :text
      add :ts, :bigint, null: false
    end

    create unique_index(:receipts, [:room_id, :user_id, :receipt_type])

    # Federation inbound transaction dedup
    create table(:federation_inbound_txns) do
      add :origin, :text, null: false
      add :txn_id, :text, null: false
      add :processed, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:federation_inbound_txns, [:origin, :txn_id])

    # Client event send idempotency (txn_id dedup per device)
    create table(:client_txns, primary_key: false) do
      add :user_id, :text, null: false
      add :device_id, :text, null: false
      add :txn_id, :text, null: false
      add :event_id, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:client_txns, [:user_id, :device_id, :txn_id])

    # Remote server signing key cache
    create table(:server_keys, primary_key: false) do
      add :server_name, :text, null: false
      add :key_id, :text, null: false
      add :public_key_b64, :text, null: false
      add :valid_until_ts, :bigint, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:server_keys, [:server_name, :key_id])

    # Federation outbound queue
    create table(:federation_queue) do
      add :destination, :text, null: false
      add :event_id, :text, null: false
      add :pdu, :map, null: false
      add :attempts, :smallint, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec, null: false
      add :status, :text, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:federation_queue, [:destination, :next_attempt_at],
             where: "status = 'pending'",
             name: :federation_queue_work_idx
           )
  end
end
