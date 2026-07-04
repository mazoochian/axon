defmodule AxonCore.Repo.Migrations.CreateDehydratedDevices do
  use Ecto.Migration

  def change do
    create table(:dehydrated_devices, primary_key: false) do
      add :user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        primary_key: true

      add :device_id, :text, null: false
      add :device_data, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
