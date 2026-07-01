defmodule AxonWeb.Plug.MatrixContentType do
  @moduledoc "Strips charset from JSON Content-Type header (Matrix spec requires bare application/json)."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      case get_resp_header(conn, "content-type") do
        ["application/json" <> _] -> put_resp_header(conn, "content-type", "application/json")
        _ -> conn
      end
    end)
  end
end
