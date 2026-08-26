defmodule AxonWeb.UserDirectoryController do
  use Phoenix.Controller, formats: [:json]

  import Ecto.Query
  alias AxonCore.Repo

  def search(conn, params) do
    term = params["search_term"] || ""
    limit = min(params["limit"] || 10, 50)
    requester = conn.assigns.current_user_id

    {results, limited?} =
      if String.length(term) < 1 do
        {[], false}
      else
        pattern = "%#{String.downcase(term)}%"

        candidates =
          from(candidate in "room_memberships",
            join: room in "rooms",
            on: room.room_id == candidate.room_id,
            left_join: requester_membership in "room_memberships",
            on:
              requester_membership.room_id == candidate.room_id and
                requester_membership.user_id == ^requester and
                requester_membership.membership == "join",
            where:
              candidate.membership == "join" and candidate.user_id != ^requester and
                (room.is_public == true or not is_nil(requester_membership.user_id)),
            distinct: true,
            select: %{user_id: candidate.user_id}
          )

        rows =
          Repo.all(
            from(u in "users",
              join: candidate in subquery(candidates),
              on: candidate.user_id == u.user_id,
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
              order_by: [asc: u.user_id],
              limit: ^(limit + 1)
            )
          )

        results =
          rows
          |> Enum.take(limit)
          |> Enum.map(fn row ->
            %{"user_id" => row.user_id}
            |> maybe_put("display_name", row.display_name)
            |> maybe_put("avatar_url", row.avatar_url)
          end)

        {results, length(rows) > limit}
      end

    json(conn, %{"results" => results, "limited" => limited?})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
