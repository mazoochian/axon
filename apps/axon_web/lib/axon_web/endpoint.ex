defmodule AxonWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :axon_web

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug AxonWeb.Plug.MatrixContentType
  plug AxonWeb.Plug.JsonBodyParser
  plug Plug.MethodOverride
  plug Plug.Head

  plug AxonWeb.Router
end
