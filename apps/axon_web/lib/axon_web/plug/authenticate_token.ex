defmodule AxonWeb.Plug.AuthenticateToken do
  @moduledoc "Extracts and validates the Bearer token, setting conn assigns."

  import Plug.Conn
  alias AxonCore.UserStore

  def init(opts), do: opts

  def call(conn, _opts) do
    case extract_token(conn) do
      nil ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.json(%{
          "errcode" => "M_MISSING_TOKEN",
          "error" => "Missing access token"
        })
        |> halt()

      raw_token ->
        case UserStore.validate_token(raw_token) do
          {:ok, {user_id, device_id}} ->
            conn
            |> assign(:current_user_id, user_id)
            |> assign(:current_device_id, device_id)
            |> assign(:current_token, raw_token)

          :error ->
            conn
            |> put_status(401)
            |> Phoenix.Controller.json(%{
              "errcode" => "M_UNKNOWN_TOKEN",
              "error" => "Invalid access token"
            })
            |> halt()
        end
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      _ -> conn.query_params["access_token"]
    end
  end
end
