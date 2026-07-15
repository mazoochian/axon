defmodule AxonWeb.HealthController do
  @moduledoc """
  Ops-facing liveness/readiness probes — distinct from `VersionController`'s
  `/versions`, which is a Matrix spec endpoint, not a generic health check.
  Mounted unauthenticated on both listeners so a load balancer/orchestrator
  can probe either port directly.
  """

  use Phoenix.Controller, formats: [:json]

  alias AxonCore.Repo

  # Liveness: process is up and able to respond. No dependency checks —
  # this should never fail while the BEAM is running, by design.
  def health(conn, _params) do
    json(conn, %{"status" => "ok"})
  end

  # Readiness: process is up AND its database dependency is reachable.
  def ready(conn, _params) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _result} ->
        json(conn, %{"status" => "ok"})

      {:error, _reason} ->
        conn
        |> put_status(503)
        |> json(%{"status" => "error", "reason" => "database unreachable"})
    end
  end
end
