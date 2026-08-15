defmodule AxonCore.Repo.Migrations.AddEventRedactionTracking do
  use Ecto.Migration

  def change do
    alter table(:events) do
      add :redacted, :boolean, null: false, default: false
      add :redacted_because, :text
    end
  end
end
