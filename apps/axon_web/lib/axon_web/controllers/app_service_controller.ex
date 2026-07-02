defmodule AxonWeb.AppServiceController do
  use Phoenix.Controller, formats: [:json]

  alias AxonWeb.AppService.Manager

  # PUT /_matrix/app/v1/transactions/:txn_id
  # Receives events from an application service.
  def transaction(conn, %{"txn_id" => _txn_id} = params) do
    token = get_token(conn, params)

    case Manager.verify_as_token(token) do
      {:ok, _reg} ->
        # Acknowledge receipt. In Phase 4 we don't store inbound AS events;
        # they arrive as federation PDUs via the normal event flow.
        json(conn, %{})

      :error ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Invalid as_token"})
    end
  end

  defp get_token(conn, params) do
    # Clients may send via query param or Authorization header
    params["access_token"] ||
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> nil
      end
  end
end
