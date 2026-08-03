defmodule AxonCore.Repo.Migrations.CreateUserProfileFields do
  use Ecto.Migration

  def change do
    # Generic (non-displayname/avatar_url) profile fields, per
    # https://spec.matrix.org/v1.18/client-server-api/#profiles (added in
    # Matrix 1.16). `key` is the arbitrary/namespaced profile field name
    # (e.g. "m.tz" or "com.example.foo"); `value` holds any JSON value
    # (string, number, bool, object, or array) via the jsonb-backed :map
    # column type.
    create table(:user_profile_fields, primary_key: false) do
      add(:user_id, references(:users, column: :user_id, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:key, :text, null: false)
      add(:value, :map, null: false)
    end

    create(unique_index(:user_profile_fields, [:user_id, :key]))
  end
end
