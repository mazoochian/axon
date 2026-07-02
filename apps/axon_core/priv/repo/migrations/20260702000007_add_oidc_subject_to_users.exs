defmodule AxonCore.Repo.Migrations.AddOidcSubjectToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :oidc_subject, :text
    end

    create unique_index(:users, [:oidc_subject], where: "oidc_subject IS NOT NULL")
  end
end
