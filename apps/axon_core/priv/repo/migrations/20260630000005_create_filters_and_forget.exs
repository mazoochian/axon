defmodule AxonCore.Repo.Migrations.CreateFiltersAndForget do
  use Ecto.Migration

  def change do
    create table(:user_filters, primary_key: false) do
      add :filter_id, :text, primary_key: true
      add :user_id, :text, null: false
      add :filter, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_filters, [:user_id])

    # Add forgotten flag to room_memberships
    alter table(:room_memberships) do
      add :forgotten, :boolean, default: false, null: false
    end
  end
end
