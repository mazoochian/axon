defmodule AxonWeb.ReportController do
  @moduledoc """
  Content reporting (`POST /rooms/:roomId/report/:eventId` and the
  whole-room variant). Reports are just recorded for admin review — Axon
  has no moderation UI yet, so this is intentionally a write-only sink.
  """

  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  alias AxonCore.Repo

  # POST /_matrix/client/v3/rooms/:room_id/report/:event_id
  def report_event(conn, %{"room_id" => room_id, "event_id" => event_id} = params) do
    insert_report(room_id, event_id, conn.assigns.current_user_id, params)
    json(conn, %{})
  end

  # POST /_matrix/client/v3/rooms/:room_id/report
  def report_room(conn, %{"room_id" => room_id} = params) do
    insert_report(room_id, nil, conn.assigns.current_user_id, params)
    json(conn, %{})
  end

  defp insert_report(room_id, event_id, reporter_id, params) do
    Repo.insert_all("reports", [
      %{
        room_id: room_id,
        event_id: event_id,
        reporter_id: reporter_id,
        reason: params["reason"],
        score: params["score"],
        inserted_at: DateTime.utc_now(:microsecond)
      }
    ])
  end
end
