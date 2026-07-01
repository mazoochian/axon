defmodule AxonWeb.FilterController do
  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  import Ecto.Query
  alias AxonCore.Repo

  def create(conn, %{"user_id" => user_id} = params) do
    requester = conn.assigns.current_user_id

    if requester != user_id do
      conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Forbidden"})
    else
      filter = Map.drop(params, ["user_id"])
      filter_json = Jason.encode!(filter)

      # Store filter in DB and return a filter_id
      filter_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

      Repo.insert_all("user_filters", [
        %{
          filter_id: filter_id,
          user_id: user_id,
          filter: filter_json,
          inserted_at: DateTime.utc_now(:microsecond),
          updated_at: DateTime.utc_now(:microsecond)
        }
      ], on_conflict: :nothing)

      json(conn, %{"filter_id" => filter_id})
    end
  end

  def get(conn, %{"user_id" => user_id, "filter_id" => filter_id}) do
    requester = conn.assigns.current_user_id

    if requester != user_id do
      conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Forbidden"})
    else
      case Repo.one(
             from f in "user_filters",
               where: f.filter_id == ^filter_id and f.user_id == ^user_id,
               select: f.filter
           ) do
        nil -> {:error, :not_found}
        filter_json -> json(conn, Jason.decode!(filter_json))
      end
    end
  end
end
