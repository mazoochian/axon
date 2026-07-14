defmodule AxonCore.Repo.Migrations.CreateUrlPreviews do
  use Ecto.Migration

  def change do
    create table(:url_previews, primary_key: false) do
      add(:url, :text, null: false)
      add(:data, :map, null: false)
      add(:fetched_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:url_previews, [:url]))
  end
end
