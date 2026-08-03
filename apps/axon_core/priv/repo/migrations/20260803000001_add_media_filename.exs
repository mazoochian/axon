defmodule AxonCore.Repo.Migrations.AddMediaFilename do
  use Ecto.Migration

  def change do
    alter table(:media) do
      add :filename, :text
    end
  end
end
