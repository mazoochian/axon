defmodule AxonWeb.Plug.RoomLogMetadata do
  @moduledoc """
  Sets `room_id` in `Logger.metadata/1` from the `:room_id` path param when
  present, so it shows up in the console format's `[:request_id, :room_id,
  :user_id]` metadata (`config/config.exs`) alongside `user_id` (set by
  `AxonWeb.Plug.AuthenticateToken`). No-ops on routes without a `room_id`
  param.
  """

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.path_params["room_id"] do
      nil -> :ok
      room_id -> Logger.metadata(room_id: room_id)
    end

    conn
  end
end
