defmodule AxonCore.ProfileFields do
  @moduledoc """
  Storage for arbitrary/namespaced user profile fields per
  https://spec.matrix.org/v1.18/client-server-api/#profiles (the generic
  `{keyName}` profile endpoints, added in Matrix 1.16).

  `displayname` and `avatar_url` are NOT stored here — they continue to
  live in `user_profiles` (see `AxonCore.UserStore`) and are exposed
  through the generic endpoints by having the controller special-case
  those two key names and delegate to `UserStore`. This module only
  backs the "everything else" custom/namespaced fields (e.g. `m.tz`,
  `com.example.foo`), stored one row per (user_id, key) with an
  arbitrary JSON value.
  """

  import Ecto.Query
  alias AxonCore.Repo

  @doc "Fetches a single custom field's value, or `:error` if unset."
  def get(user_id, key) do
    case Repo.one(
           from(f in "user_profile_fields",
             where: f.user_id == ^user_id and f.key == ^key,
             select: f.value
           )
         ) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  @doc "Returns all custom fields for a user as a `%{key => value}` map."
  def list(user_id) do
    Repo.all(
      from(f in "user_profile_fields",
        where: f.user_id == ^user_id,
        select: {f.key, f.value}
      )
    )
    |> Map.new()
  end

  @doc "Sets (creates or replaces) a single custom field's value."
  def put(user_id, key, value) do
    Repo.insert_all(
      "user_profile_fields",
      [%{user_id: user_id, key: key, value: value}],
      on_conflict: {:replace, [:value]},
      conflict_target: [:user_id, :key]
    )

    :ok
  end

  @doc "Deletes a custom field. Not an error if it was already unset."
  def delete(user_id, key) do
    Repo.delete_all(
      from(f in "user_profile_fields", where: f.user_id == ^user_id and f.key == ^key)
    )

    :ok
  end
end
