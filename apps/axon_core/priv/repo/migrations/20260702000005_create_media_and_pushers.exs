defmodule AxonCore.Repo.Migrations.CreateMediaAndPushers do
  use Ecto.Migration

  def change do
    create table(:media, primary_key: false) do
      add :media_id, :text, primary_key: true
      add :origin_server, :text, null: false
      add :content_type, :text, null: false
      add :file_size, :bigint
      add :storage_path, :text
      add :uploader, :text
      add :created_at, :utc_datetime_usec, default: fragment("NOW()")
    end

    create table(:pushers, primary_key: false) do
      add :user_id, :text, null: false
      add :device_id, :text, null: false
      add :kind, :text, null: false
      add :app_id, :text, null: false
      add :app_display_name, :text, null: false
      add :device_display_name, :text, null: false
      add :pushkey, :text, null: false
      add :lang, :text, null: false, default: "en"
      add :data, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
    end

    create unique_index(:pushers, [:user_id, :app_id, :pushkey])
    create index(:pushers, [:user_id])
  end
end
