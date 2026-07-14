defmodule AxonCore.Repo.Migrations.Phase13AdminFields do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:shadow_banned, :boolean, null: false, default: false)
    end

    alter table(:media) do
      add(:quarantined, :boolean, null: false, default: false)
    end

    alter table(:rooms) do
      add(:blocked, :boolean, null: false, default: false)
    end
  end
end
