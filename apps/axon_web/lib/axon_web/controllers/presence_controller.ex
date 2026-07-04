defmodule AxonWeb.PresenceController do
  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  alias AxonSync.Presence

  # GET /_matrix/client/v3/presence/:user_id/status
  def get_status(conn, %{"user_id" => user_id}) do
    json(conn, Presence.get(user_id))
  end

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
