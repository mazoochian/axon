defmodule AxonWeb.PresenceController do
  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  alias AxonSync.Presence
  alias AxonWeb.SyncHelpers

  # GET /_matrix/client/v3/presence/:user_id/status
  #
  # Matrix's presence visibility rule is the same one /sync applies (see
  # AxonWeb.SyncHelpers.get_presence_events/3): you see your own presence,
  # and the presence of anyone you share a joined room with — nobody else's.
  # This endpoint used to skip the check entirely, so any authenticated
  # account could read online/offline state, last-active timestamps and
  # status messages for *every* user on the server, related to them or not:
  # an activity tracker over the whole user base. Deliberately reuses
  # `shared_room_user_ids/1`, the exact set /sync builds, rather than a
  # second same-room predicate that could answer differently.
  def get_status(conn, %{"user_id" => user_id}) do
    requester = conn.assigns[:current_user_id]

    if visible_to?(requester, user_id) do
      json(conn, Presence.get(user_id))
    else
      conn
      |> Plug.Conn.put_status(403)
      |> json(%{
        "errcode" => "M_FORBIDDEN",
        "error" => "You are not allowed to see this user's presence state"
      })
    end
  end

  defp visible_to?(nil, _target), do: false
  defp visible_to?(requester, requester), do: true

  defp visible_to?(requester, target),
    do: target in SyncHelpers.shared_room_user_ids(requester)

  # PUT /_matrix/client/v3/presence/:user_id/status
  # Named put_status/2 (same name as Plug.Conn/Phoenix.Controller's status
  # helper) — every HTTP-status call below is fully qualified as
  # Plug.Conn.put_status/2 so it doesn't recurse into this action instead.
  def put_status(conn, %{"user_id" => user_id} = params) do
    current_user_id = conn.assigns.current_user_id

    if user_id != current_user_id do
      conn
      |> Plug.Conn.put_status(403)
      |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Cannot set another user's presence"})
    else
      presence = params["presence"]

      if presence in ["online", "unavailable", "offline"] do
        Presence.set_presence(user_id, presence, params["status_msg"])
        json(conn, %{})
      else
        conn
        |> Plug.Conn.put_status(400)
        |> json(%{
          "errcode" => "M_INVALID_PARAM",
          "error" => "presence must be online, unavailable, or offline"
        })
      end
    end
  end
end
