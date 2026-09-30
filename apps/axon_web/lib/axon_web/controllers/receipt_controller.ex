defmodule AxonWeb.ReceiptController do
  use Phoenix.Controller, formats: [:json]

  alias AxonCore.{EventStore, Repo}

  @receipt_types ["m.read", "m.read.private", "m.fully_read"]

  # POST /_matrix/client/v3/rooms/:room_id/receipt/:receipt_type/:event_id
  def receipt(conn, %{
        "room_id" => room_id,
        "receipt_type" => receipt_type,
        "event_id" => event_id
      }) do
    user_id = conn.assigns.current_user_id

    cond do
      receipt_type not in @receipt_types ->
        conn
        |> put_status(400)
        |> json(%{
          "errcode" => "M_INVALID_PARAM",
          "error" => "Receipt type must be one of #{Enum.join(@receipt_types, ", ")}"
        })

      not EventStore.joined?(room_id, user_id) ->
        not_joined(conn)

      true ->
        put_marker(room_id, user_id, receipt_type, event_id, System.system_time(:millisecond))
        json(conn, %{})
    end
  end

  # POST /_matrix/client/v3/rooms/:room_id/read_markers
  def read_markers(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id

    if EventStore.joined?(room_id, user_id) do
      ts = System.system_time(:millisecond)

      for type <- @receipt_types, event_id = params[type] do
        put_marker(room_id, user_id, type, event_id, ts)
      end

      json(conn, %{})
    else
      not_joined(conn)
    end
  end

  defp not_joined(conn) do
    conn
    |> put_status(403)
    |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})
  end

  # m.fully_read is a room account-data marker, not a receipt.
  defp put_marker(room_id, user_id, "m.fully_read", event_id, _ts) do
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

  defp put_marker(room_id, user_id, receipt_type, event_id, ts),
    do: store_receipt(room_id, user_id, receipt_type, event_id, ts)

  # Wakes any long-polling /sync for the room's members (previously nothing
  # broadcast at all, so a receipt with no accompanying new timeline event
  # in the same room sat unseen until the recipient's timeout elapsed, or
  # some unrelated event happened to touch the room), relays m.read
  # receipts (not m.read.private, which per spec never leaves the user's own
  # devices/services) to remote servers sharing the room, and pushes both
  # kinds to any application service that opted into ephemeral data and is
  # in this receipt's audience.
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
    dispatch_appservice_receipt(room_id, user_id, receipt_type, event_id, ts)
  end

  # AS ephemeral push (AS spec, "Pushing ephemeral data"), in the
  # Client-Server-API `m.receipt` content shape rather than federation's
  # `event_ids` list form. An m.read.private receipt only ever reaches an AS
  # that owns the receipt's own user (dispatch_ephemeral/5's `private?: true`)
  # — it is never broadcast to every AS bridging the room the way a public
  # m.read receipt is.
  defp dispatch_appservice_receipt(room_id, user_id, receipt_type, event_id, ts) do
    content = %{event_id => %{receipt_type => %{user_id => %{"ts" => ts}}}}

    AxonWeb.AppService.Manager.dispatch_ephemeral(
      "m.receipt",
      room_id,
      user_id,
      content,
      private?: receipt_type == "m.read.private"
    )
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
