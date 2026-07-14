defmodule AxonCore.Repo.Migrations.CreateServerNoticeRooms do
  use Ecto.Migration

  def change do
    create table(:server_notice_rooms, primary_key: false) do
      add(:user_id, :text, null: false)
      add(:room_id, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:server_notice_rooms, [:user_id]))
  end
end
