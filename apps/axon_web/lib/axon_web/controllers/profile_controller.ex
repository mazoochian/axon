defmodule AxonWeb.ProfileController do
  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  alias AxonCore.{EventStore, UserStore}

  # GET /_matrix/client/v3/profile/:user_id
  def show(conn, %{"user_id" => user_id}) do
    with {:ok, profile} <- UserStore.get_profile(user_id) do
      resp = %{}
      resp = if profile.displayname, do: Map.put(resp, "displayname", profile.displayname), else: resp
      resp = if profile.avatar_url, do: Map.put(resp, "avatar_url", profile.avatar_url), else: resp
      json(conn, resp)
    end
  end

  # GET /_matrix/client/v3/profile/:user_id/displayname
  def get_displayname(conn, %{"user_id" => user_id}) do
    with {:ok, profile} <- UserStore.get_profile(user_id) do
      json(conn, %{"displayname" => profile.displayname})
    end
  end

  # PUT /_matrix/client/v3/profile/:user_id/displayname
  def set_displayname(conn, %{"user_id" => user_id, "displayname" => displayname}) do
    if user_id != conn.assigns.current_user_id do
      conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Cannot set another user's profile"})
    else
      with {:ok, _} <- UserStore.update_profile(user_id, %{displayname: displayname}) do
        Task.Supervisor.start_child(Axon.TaskSupervisor, fn -> propagate_profile_to_rooms(user_id) end)
        json(conn, %{})
      end
    end
  end

  def set_displayname(conn, _params), do: json(conn, %{})

  # GET /_matrix/client/v3/profile/:user_id/avatar_url
  def get_avatar_url(conn, %{"user_id" => user_id}) do
    with {:ok, profile} <- UserStore.get_profile(user_id) do
      json(conn, %{"avatar_url" => profile.avatar_url})
    end
  end

  # PUT /_matrix/client/v3/profile/:user_id/avatar_url
  def set_avatar_url(conn, %{"user_id" => user_id, "avatar_url" => avatar_url}) do
    if user_id != conn.assigns.current_user_id do
      conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Cannot set another user's profile"})
    else
      with {:ok, _} <- UserStore.update_profile(user_id, %{avatar_url: avatar_url}) do
        Task.Supervisor.start_child(Axon.TaskSupervisor, fn -> propagate_profile_to_rooms(user_id) end)
        json(conn, %{})
      end
    end
  end

  def set_avatar_url(conn, _params), do: json(conn, %{})

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Propagates the current profile (displayname + avatar_url) to all joined
  # rooms by sending updated m.room.member state events.
  # Per spec §10.5.1, servers SHOULD propagate profile changes to rooms.
  defp propagate_profile_to_rooms(user_id) do
    with {:ok, profile} <- UserStore.get_profile(user_id) do
      profile_fields = %{}
      profile_fields = if profile.displayname, do: Map.put(profile_fields, "displayname", profile.displayname), else: profile_fields
      profile_fields = if profile.avatar_url,  do: Map.put(profile_fields, "avatar_url",  profile.avatar_url),  else: profile_fields

      EventStore.get_joined_rooms(user_id)
      |> Enum.each(fn room_id ->
        case AxonRoom.RoomProcess.get_state_event(room_id, "m.room.member", user_id) do
          nil ->
            :ok

          event_map ->
            current_content = event_map["content"] || %{}
            new_content = Map.merge(current_content, profile_fields)
            AxonRoom.RoomProcess.send_event(room_id, user_id, "m.room.member", new_content, state_key: user_id)
        end
      end)
    end
  end
end
