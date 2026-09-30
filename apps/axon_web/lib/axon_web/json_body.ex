defmodule AxonWeb.JsonBody do
  @moduledoc """
  The request's JSON body alone, without the path/query params Phoenix
  merges into `params` (which would otherwise leak e.g. `?access_token=`
  into stored content).
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  @doc "`{:ok, map}` for a JSON object body (or no body), `:error` for any other JSON value."
  def object(%Plug.Conn{body_params: %{"_json" => _}}), do: :error
  def object(%Plug.Conn{body_params: %{} = body}) when not is_struct(body), do: {:ok, body}
  def object(_conn), do: {:ok, %{}}

  def not_object(conn) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_BAD_JSON", "error" => "Content must be a JSON object"})
  end
end
