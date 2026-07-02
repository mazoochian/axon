defmodule AxonWeb.AccountDataController do
  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  import Ecto.Query
  alias AxonCore.Repo

  # GET /_matrix/client/v3/user/:user_id/account_data/:type
  def get(conn, %{"user_id" => user_id, "type" => type}) do
    requester = conn.assigns.current_user_id

    if user_id != requester do
      {:error, :forbidden}
    else
      case Repo.one(
             from a in "account_data",
               where: a.user_id == ^user_id and a.type == ^type,
               select: a.content
           ) do
        nil -> {:error, :not_found}
        content -> json(conn, content)
      end
    end
  end

  # PUT /_matrix/client/v3/user/:user_id/account_data/:type
  def put(conn, %{"user_id" => user_id, "type" => type} = params) do
    requester = conn.assigns.current_user_id

    if user_id != requester do
      {:error, :forbidden}
    else
      content = Map.drop(params, ~w(user_id type))

      Repo.insert_all("account_data", [
        %{
          user_id: user_id,
          type: type,
          content: content
        }
      ],
      on_conflict: {:replace, [:content]},
      conflict_target: [:user_id, :type])

      Repo.insert_all("account_data_stream", [%{user_id: user_id, type: type}])

      json(conn, %{})
    end
  end

  # GET /_matrix/client/v3/user/:user_id/rooms/:room_id/account_data/:type
  def get_room(conn, %{"user_id" => user_id, "room_id" => room_id, "type" => type}) do
    requester = conn.assigns.current_user_id

    if user_id != requester do
      {:error, :forbidden}
    else
      case Repo.one(
             from a in "room_account_data",
               where: a.user_id == ^user_id and a.room_id == ^room_id and a.type == ^type,
               select: a.content
           ) do
        nil -> {:error, :not_found}
        content -> json(conn, content)
      end
    end
  end

  # PUT /_matrix/client/v3/user/:user_id/rooms/:room_id/account_data/:type
  def put_room(conn, %{"user_id" => user_id, "room_id" => room_id, "type" => type} = params) do
    requester = conn.assigns.current_user_id

    if user_id != requester do
      {:error, :forbidden}
    else
      content = Map.drop(params, ~w(user_id room_id type))

      Repo.insert_all("room_account_data", [
        %{
          user_id: user_id,
          room_id: room_id,
          type: type,
          content: content
        }
      ],
      on_conflict: {:replace, [:content]},
      conflict_target: [:user_id, :room_id, :type])

      json(conn, %{})
    end
  end
end
