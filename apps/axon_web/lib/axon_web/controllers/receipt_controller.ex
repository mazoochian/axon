defmodule AxonWeb.ReceiptController do
  use Phoenix.Controller, formats: [:json]

  alias AxonCore.Repo

  # POST /_matrix/client/v3/rooms/:room_id/receipt/:receipt_type/:event_id
  def receipt(conn, %{"room_id" => room_id, "receipt_type" => receipt_type, "event_id" => event_id}) do
    user_id = conn.assigns.current_user_id
    ts = System.system_time(:millisecond)

    Repo.insert_all("receipts",
      [%{room_id: room_id, user_id: user_id, receipt_type: receipt_type, event_id: event_id, ts: ts}],
      on_conflict: {:replace, [:event_id, :ts]},
      conflict_target: [:room_id, :user_id, :receipt_type]
    )

    json(conn, %{})
  end

  # POST /_matrix/client/v3/rooms/:room_id/read_markers
  def read_markers(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id
    ts = System.system_time(:millisecond)

    if event_id = params["m.read"] do
      Repo.insert_all("receipts",
        [%{room_id: room_id, user_id: user_id, receipt_type: "m.read", event_id: event_id, ts: ts}],
        on_conflict: {:replace, [:event_id, :ts]},
        conflict_target: [:room_id, :user_id, :receipt_type]
      )
    end

    if event_id = params["m.read.private"] do
      Repo.insert_all("receipts",
        [%{room_id: room_id, user_id: user_id, receipt_type: "m.read.private", event_id: event_id, ts: ts}],
        on_conflict: {:replace, [:event_id, :ts]},
        conflict_target: [:room_id, :user_id, :receipt_type]
      )
    end

    if event_id = params["m.fully_read"] do
      Repo.insert_all("room_account_data",
        [%{user_id: user_id, room_id: room_id, type: "m.fully_read", content: %{"event_id" => event_id}}],
        on_conflict: {:replace, [:content]},
        conflict_target: [:user_id, :room_id, :type]
      )
    end

    json(conn, %{})
  end
end
