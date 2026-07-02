defmodule AxonWeb.Plug.CORS do
  import Plug.Conn

  @headers [
    {"access-control-allow-origin", "*"},
    {"access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS"},
    {"access-control-allow-headers", "Authorization, Content-Type, X-Requested-With"},
    {"access-control-max-age", "86400"}
  ]

  def init(opts), do: opts

  def call(%{method: "OPTIONS"} = conn, _opts) do
    conn
    |> put_cors_headers()
    |> send_resp(200, "")
    |> halt()
  end

  def call(conn, _opts) do
    put_cors_headers(conn)
  end

  defp put_cors_headers(conn) do
    Enum.reduce(@headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
  end
end
