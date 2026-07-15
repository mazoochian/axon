defmodule AxonWeb.Plug.JsonBodyParser do
  @moduledoc "Parses JSON request bodies and returns M_NOT_JSON on parse failure."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> Plug.Parsers.call(
      Plug.Parsers.init(
        parsers: [:json],
        pass: ["*/*"],
        json_decoder: Jason
      )
    )
  rescue
    _e in Plug.Parsers.ParseError ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        400,
        Jason.encode!(%{"errcode" => "M_NOT_JSON", "error" => "Request body is not valid JSON"})
      )
      |> halt()
  end
end
