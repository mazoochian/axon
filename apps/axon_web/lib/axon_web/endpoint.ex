defmodule AxonWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :axon_web

  # Powers LiveDashboard (admin-gated, see router.ex) — the only LiveView
  # usage in this otherwise-JSON-only API server.
  socket("/live", Phoenix.LiveView.Socket)

  plug(AxonWeb.Plug.CORS)
  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(AxonWeb.Plug.MatrixContentType)
  plug(AxonWeb.Plug.JsonBodyParser)
  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(AxonWeb.Router)
end
