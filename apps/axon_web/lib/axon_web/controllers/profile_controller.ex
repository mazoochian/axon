defmodule AxonWeb.ProfileController do
  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  alias AxonCore.UserStore

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
        json(conn, %{})
      end
    end
  end

  def set_avatar_url(conn, _params), do: json(conn, %{})
end
