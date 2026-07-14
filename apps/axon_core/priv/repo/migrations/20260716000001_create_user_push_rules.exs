defmodule AxonCore.Repo.Migrations.CreateUserPushRules do
  use Ecto.Migration

  def change do
    create table(:user_push_rules, primary_key: false) do
      add(:user_id, :text, null: false)
      add(:kind, :text, null: false)
      add(:rule_id, :text, null: false)
      # true when this row overrides a server-default (".m.rule.*") rule's
      # enabled/actions rather than defining a whole new custom rule.
      add(:is_default, :boolean, null: false, default: false)
      add(:pattern, :text)
      add(:conditions, :map)
      add(:actions, :map)
      add(:enabled, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:user_push_rules, [:user_id, :kind, :rule_id]))
  end
end
