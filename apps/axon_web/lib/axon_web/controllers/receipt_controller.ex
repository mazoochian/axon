defmodule AxonWeb.ReceiptController do
  use Phoenix.Controller, formats: [:json]

  # POST /_matrix/client/v3/rooms/:room_id/receipt/:receipt_type/:event_id
  def receipt(conn, _params) do
    json(conn, %{})
  end

  # POST /_matrix/client/v3/rooms/:room_id/read_markers
  def read_markers(conn, _params) do
    json(conn, %{})
  end
end
