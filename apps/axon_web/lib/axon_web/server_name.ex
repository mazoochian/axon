defmodule AxonWeb.ServerName do
  @moduledoc "This homeserver's own server name."

  def get, do: Application.fetch_env!(:axon_web, :server_name)

  def local?(id), do: AxonCore.MatrixId.from_server?(id, get())
end
