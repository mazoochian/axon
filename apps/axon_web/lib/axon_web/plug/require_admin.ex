defmodule AxonWeb.Plug.RequireAdmin do
  @moduledoc """
  Gates the admin API (`/_synapse/admin/v1/...`). Must run after
  `AxonWeb.Plug.AuthenticateToken` (needs `conn.assigns.current_user_id`).
  Halts with 403 unless that user has `users.admin == true`.
  """

  import Plug.Conn
  alias AxonCore.Repo

  def init(opts), do: opts

  def call(conn, _opts) do
    if admin?(conn.assigns[:current_user_id]) do
      conn
    else
      conn
      |> put_status(403)
      |> Phoenix.Controller.json(%{
        "errcode" => "M_FORBIDDEN",
        "error" => "Admin access required"
      })
      |> halt()
    end
  end

  defp admin?(nil), do: false

  defp admin?(user_id) do
    import Ecto.Query
    Repo.one(from(u in "users", where: u.user_id == ^user_id, select: u.admin)) || false
  end
end
