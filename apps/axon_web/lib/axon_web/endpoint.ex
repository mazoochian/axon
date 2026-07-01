defmodule AxonWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :axon_web

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug AxonWeb.Plug.MatrixContentType

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head

  plug AxonWeb.Router
end
