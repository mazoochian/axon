defmodule AxonWeb.UserDirectoryController do
  use Phoenix.Controller, formats: [:json]

  import Ecto.Query
  alias AxonCore.Repo

  def search(conn, params) do
    term = params["search_term"] || ""
    limit = min(params["limit"] || 10, 50)

    results =
      if String.length(term) < 1 do
        []
      else
        pattern = "%#{String.downcase(term)}%"

        Repo.all(
          from(u in "users",
            left_join: p in "user_profiles",
            on: u.user_id == p.user_id,
            where:
              not u.deactivated and
                (ilike(u.user_id, ^pattern) or ilike(p.displayname, ^pattern)),
            select: %{
              user_id: u.user_id,
              display_name: p.displayname,
              avatar_url: p.avatar_url
            },
            limit: ^limit
          )
        )
        |> Enum.map(fn row ->
          %{"user_id" => row.user_id}
          |> maybe_put("display_name", row.display_name)
          |> maybe_put("avatar_url", row.avatar_url)
        end)
      end

    json(conn, %{"results" => results, "limited" => length(results) == limit})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
