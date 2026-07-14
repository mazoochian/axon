defmodule AxonWeb.ReceiptController do
  use Phoenix.Controller, formats: [:json]

  alias AxonCore.{EventStore, Repo}

  # POST /_matrix/client/v3/rooms/:room_id/receipt/:receipt_type/:event_id
  def receipt(conn, %{
        "room_id" => room_id,
        "receipt_type" => receipt_type,
        "event_id" => event_id
      }) do
    user_id = conn.assigns.current_user_id
    ts = System.system_time(:millisecond)

    store_receipt(room_id, user_id, receipt_type, event_id, ts)

    json(conn, %{})
  end

  # POST /_matrix/client/v3/rooms/:room_id/read_markers
  def read_markers(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id
    ts = System.system_time(:millisecond)

    if event_id = params["m.read"] do
      store_receipt(room_id, user_id, "m.read", event_id, ts)
    end

    if event_id = params["m.read.private"] do
      store_receipt(room_id, user_id, "m.read.private", event_id, ts)
    end

    if event_id = params["m.fully_read"] do
      Repo.insert_all(
        "room_account_data",
        [
          %{
            user_id: user_id,
            room_id: room_id,
            type: "m.fully_read",
            content: %{"event_id" => event_id}
          }
        ],
        on_conflict: {:replace, [:content]},
        conflict_target: [:user_id, :room_id, :type]
      )
    end

    json(conn, %{})
  end

  # Wakes any long-polling /sync for the room's members (previously nothing
  # broadcast at all, so a receipt with no accompanying new timeline event
  # in the same room sat unseen until the recipient's timeout elapsed, or
  # some unrelated event happened to touch the room) and relays m.read
  # receipts (not m.read.private, which per spec never leaves the user's own
  # devices) to remote servers sharing the room.
  defp store_receipt(room_id, user_id, receipt_type, event_id, ts) do
    Repo.insert_all(
      "receipts",
      [
        %{
          room_id: room_id,
          user_id: user_id,
          receipt_type: receipt_type,
          event_id: event_id,
          ts: ts
        }
      ],
      on_conflict: {:replace, [:event_id, :ts]},
      conflict_target: [:room_id, :user_id, :receipt_type]
    )

    EventStore.record_ephemeral_update(room_id)
    if receipt_type == "m.read", do: federate_receipt(room_id, user_id, event_id, ts)
  end

  defp federate_receipt(room_id, user_id, event_id, ts) do
    case EventStore.remote_servers_for_room(room_id) do
      [] ->
        :ok

      remote_servers ->
        edu = %{
          "edu_type" => "m.receipt",
          "content" => %{
            room_id => %{
              "m.read" => %{
                user_id => %{"data" => %{"ts" => ts}, "event_ids" => [event_id]}
              }
            }
          }
        }

        Enum.each(remote_servers, fn server ->
          Phoenix.PubSub.broadcast(Axon.PubSub, "federation:fanout", {:federate_edu, edu, server})
        end)
    end
  end
end
