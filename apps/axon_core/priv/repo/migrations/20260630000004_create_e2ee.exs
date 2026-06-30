defmodule AxonCore.Repo.Migrations.CreateE2EE do
  use Ecto.Migration

  def change do
    # Device signing keys
    create table(:device_keys, primary_key: false) do
      add :user_id, :text, null: false
      add :device_id, :text, null: false
      add :algorithms, {:array, :text}, null: false, default: []
      add :keys, :map, null: false, default: %{}
      add :signatures, :map, null: false, default: %{}
      add :stream_id, :bigserial

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:device_keys, [:user_id, :device_id])

    # One-time keys
    create table(:one_time_keys) do
      add :user_id, :text, null: false
      add :device_id, :text, null: false
      add :algorithm, :text, null: false
      add :key_id, :text, null: false
      add :key_json, :map, null: false
      add :claimed, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:one_time_keys, [:user_id, :device_id, :algorithm, :key_id])

    create index(:one_time_keys, [:user_id, :device_id, :algorithm],
             where: "claimed = false",
             name: :one_time_keys_unclaimed_idx
           )

    # Fallback keys (one per algorithm per device — not consumed on claim)
    create table(:fallback_keys, primary_key: false) do
      add :user_id, :text, null: false
      add :device_id, :text, null: false
      add :algorithm, :text, null: false
      add :key_id, :text, null: false
      add :key_json, :map, null: false
      add :used, :boolean, null: false, default: false
    end

    create unique_index(:fallback_keys, [:user_id, :device_id, :algorithm])

    # Cross-signing keys (master, self_signing, user_signing)
    create table(:cross_signing_keys, primary_key: false) do
      add :user_id, :text, null: false
      add :key_type, :text, null: false
      add :key_json, :map, null: false
    end

    create unique_index(:cross_signing_keys, [:user_id, :key_type])

    # Cross-signing signatures
    create table(:cross_signing_signatures, primary_key: false) do
      add :target_user_id, :text, null: false
      add :target_key_id, :text, null: false
      add :signing_user_id, :text, null: false
      add :signing_key_id, :text, null: false
      add :signature, :text, null: false
    end

    create unique_index(:cross_signing_signatures,
             [:target_user_id, :target_key_id, :signing_user_id, :signing_key_id]
           )

    # To-device messages
    create table(:to_device_messages) do
      add :sender, :text, null: false
      add :target_user_id, :text, null: false
      add :target_device_id, :text, null: false
      add :type, :text, null: false
      add :content, :map, null: false
      add :stream_ordering, :bigserial

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:to_device_messages, [:target_user_id, :target_device_id, :stream_ordering])
  end
end
