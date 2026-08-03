defmodule AxonWeb.NotificationsController do
  @moduledoc """
  `GET /_matrix/client/v3/notifications` — a paginated feed of this user's
  past notifications, backed by the `AxonPush.Notifications` ledger that
  `AxonPush.Dispatcher` writes to as events are dispatched. See that
  module's doc for why this is a separate, narrower-scoped table from the
  live `unread_notifications`/`notification_count` badge
  (`AxonWeb.SyncHelpers.unread_counts/2`) rather than sharing one
  implementation with it.

  `profile_tag` is always `null`: it identifies which pusher's profile_tag
  matched, but a ledger row isn't tied to any specific pusher (it's
  recorded once per recipient regardless of how many pushers, if any,
  they have registered) — there's nothing real to put there.

  `read` is computed on the fly per row by comparing its (denormalized)
  `stream_ordering` against the user's *current* `m.read` receipt position
  in that room (`AxonWeb.SyncHelpers.read_receipt_ordering/2`) — same
  on-the-fly philosophy as the unread badge, and for the same reason: it
  can't go stale relative to a receipt moving in either direction, because
  nothing is ever stored and left to rot.
  """

  use Phoenix.Controller, formats: [:json]

  alias AxonCore.EventStore
  alias AxonPush.Notifications
  alias AxonWeb.SyncHelpers

  # GET /_matrix/client/v3/notifications
  def index(conn, params) do
    user_id = conn.assigns.current_user_id

    {rows, next_token} =
      Notifications.list(user_id,
        from: params["from"],
        limit: parse_limit(params["limit"]),
        only: params["only"]
      )

    receipt_cache = build_receipt_cache(rows, user_id)

    notifications =
      Enum.map(rows, fn row ->
        receipt_ordering = Map.get(receipt_cache, row.room_id, 0)

        %{
          "actions" => row.actions,
          "event" => event_map(row),
          "profile_tag" => nil,
          "read" => row.stream_ordering <= receipt_ordering,
          "room_id" => row.room_id,
          "ts" => row.ts
        }
      end)

    resp = %{"notifications" => notifications}
    resp = if next_token, do: Map.put(resp, "next_token", next_token), else: resp

    json(conn, resp)
  end

  defp parse_limit(nil), do: nil

  defp parse_limit(limit_param) do
    case Integer.parse(limit_param) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp build_receipt_cache(rows, user_id) do
    rows
    |> Enum.map(& &1.room_id)
    |> Enum.uniq()
    |> Map.new(fn room_id -> {room_id, SyncHelpers.read_receipt_ordering(room_id, user_id)} end)
  end

  defp event_map(row) do
    case EventStore.get_event(row.event_id) do
      {:ok, event} -> EventStore.event_to_map(event)
      {:error, :not_found} -> %{"event_id" => row.event_id, "room_id" => row.room_id}
    end
  end
end
