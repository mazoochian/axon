defmodule AxonWeb.FederationEndpoint do
  use Phoenix.Endpoint, otp_app: :axon_web

  plug(AxonWeb.Plug.CORS)
  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(AxonWeb.Plug.MatrixContentType)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(AxonWeb.Router)
end
