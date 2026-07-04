defmodule AxonCore.Repo.Migrations.AddIsGuestToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :is_guest, :boolean, null: false, default: false
    end
  end
end
