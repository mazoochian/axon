defmodule AxonWeb.Plug.JsonBodyParser do
  @moduledoc "Parses JSON request bodies and returns M_NOT_JSON on parse failure."

  import Plug.Conn

  def init(opts), do: opts

  # Media uploads carry arbitrary bytes under the uploader's own Content-Type
  # (possibly application/json); MediaController reads those bodies itself,
  # so only the query params are fetched here.
  def call(%Plug.Conn{path_info: ["_matrix", "media", _version, "upload" | _]} = conn, _opts),
    do: skip_body(conn)

  def call(
        %Plug.Conn{path_info: ["_matrix", "client", _version, "media", "upload"]} = conn,
        _opts
      ),
      do: skip_body(conn)

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

  defp skip_body(conn) do
    conn = fetch_query_params(conn)
    %{conn | body_params: %{}, params: conn.query_params}
  end
end
