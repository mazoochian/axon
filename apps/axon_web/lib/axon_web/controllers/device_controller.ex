defmodule AxonWeb.DeviceController do
  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  import Ecto.Query
  alias AxonCore.{KeyStore, Repo, UserStore}
  alias AxonCore.Schema.{Device, AccessToken}

  # GET /_matrix/client/v3/devices
  def index(conn, _params) do
    user_id = conn.assigns.current_user_id
    devices = Repo.all(from d in Device, where: d.user_id == ^user_id)
    json(conn, %{"devices" => Enum.map(devices, &device_to_map/1)})
  end

  # GET /_matrix/client/v3/devices/:device_id
  def show(conn, %{"device_id" => device_id}) do
    user_id = conn.assigns.current_user_id

    case Repo.get_by(Device, user_id: user_id, device_id: device_id) do
      nil -> {:error, :not_found}
      device -> json(conn, device_to_map(device))
    end
  end

  # PUT /_matrix/client/v3/devices/:device_id
  def update(conn, %{"device_id" => device_id} = params) do
    user_id = conn.assigns.current_user_id

    case Repo.get_by(Device, user_id: user_id, device_id: device_id) do
      nil ->
        {:error, :not_found}

      _device ->
        if display_name = params["display_name"] do
          Repo.update_all(
            from(d in Device, where: d.user_id == ^user_id and d.device_id == ^device_id),
            set: [display_name: display_name]
          )
        end

        json(conn, %{})
    end
  end

  # POST /_matrix/client/v3/delete_devices
  # Requires UIA (m.login.dummy or m.login.password) — bypassed when
  # delegated OIDC auth (MSC3861) is enabled, since a valid, currently-active
  # Authorization-Server-issued token is proof enough.
  def delete_devices(conn, params) do
    user_id = conn.assigns.current_user_id
    auth = params["auth"]
    device_ids = params["devices"] || []

    cond do
      AxonWeb.Oidc.enabled?() ->
        do_delete_devices(user_id, device_ids)
        json(conn, %{})

      is_nil(auth) ->
        conn |> put_status(401) |> json(%{
          "session" => gen_session(),
          "flows" => [%{"stages" => ["m.login.password"]}, %{"stages" => ["m.login.dummy"]}],
          "params" => %{}
        })

      validate_ui_auth(user_id, auth) == :ok ->
        do_delete_devices(user_id, device_ids)
        json(conn, %{})

      true ->
        conn |> put_status(401) |> json(%{
          "session" => gen_session(),
          "flows" => [%{"stages" => ["m.login.password"]}, %{"stages" => ["m.login.dummy"]}],
          "params" => %{},
          "errcode" => "M_FORBIDDEN",
          "error" => "Invalid credentials"
        })
    end
  end

  defp do_delete_devices(user_id, device_ids) do
    Repo.update_all(
      from(t in AccessToken, where: t.user_id == ^user_id and t.device_id in ^device_ids),
      set: [valid: false]
    )

    # Purges device_keys/one_time_keys/fallback_keys per device too -- not
    # just the `devices` row -- so a removed device's identity keys don't
    # keep getting served by /keys/query forever.
    Enum.each(device_ids, &KeyStore.purge_device(user_id, &1))
    KeyStore.record_device_list_update(user_id)
  end

  # DELETE /_matrix/client/v3/devices/:device_id
  # Requires User-Interactive Authentication — bypassed when delegated OIDC
  # auth (MSC3861) is enabled, since a valid, currently-active
  # Authorization-Server-issued token is proof enough.
  def delete(conn, %{"device_id" => device_id} = params) do
    user_id = conn.assigns.current_user_id
    auth = params["auth"]

    cond do
      AxonWeb.Oidc.enabled?() ->
        do_delete_device(conn, user_id, device_id)

      is_nil(auth) ->
        conn
        |> put_status(401)
        |> json(%{
          "session" => gen_session(),
          "flows" => [%{"stages" => ["m.login.password"]}, %{"stages" => ["m.login.dummy"]}],
          "params" => %{}
        })

      validate_ui_auth(user_id, auth) == :ok ->
        do_delete_device(conn, user_id, device_id)

      true ->
        # Distinguish: auth user doesn't match current user → 403; wrong password → 401
        auth_user_id = get_auth_user_id(auth, user_id)
        if auth_user_id != user_id do
          conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Auth user does not match device owner"})
        else
          conn
          |> put_status(401)
          |> json(%{
            "session" => gen_session(),
            "flows" => [%{"stages" => ["m.login.password"]}, %{"stages" => ["m.login.dummy"]}],
            "params" => %{},
            "errcode" => "M_FORBIDDEN",
            "error" => "Invalid credentials"
          })
        end
    end
  end

  defp do_delete_device(conn, user_id, device_id) do
    case Repo.get_by(Device, user_id: user_id, device_id: device_id) do
      nil ->
        {:error, :not_found}

      _device ->
        Repo.update_all(
          from(t in AccessToken, where: t.user_id == ^user_id and t.device_id == ^device_id),
          set: [valid: false]
        )

        KeyStore.purge_device(user_id, device_id)
        KeyStore.record_device_list_update(user_id)
        json(conn, %{})
    end
  end

  defp get_auth_user_id(%{"identifier" => %{"user" => u}}, _default) when is_binary(u), do: u
  defp get_auth_user_id(%{"user" => u}, _default) when is_binary(u), do: u
  defp get_auth_user_id(_auth, default), do: default

  defp validate_ui_auth(_user_id, %{"type" => "m.login.dummy"}), do: :ok

  defp validate_ui_auth(current_user_id, %{"type" => "m.login.password"} = auth) do
    identifier = auth["identifier"] || %{}
    auth_user = identifier["user"] || auth["user"]
    password = auth["password"]
    server_name = Application.fetch_env!(:axon_web, :server_name)

    auth_user_id =
      if auth_user && String.starts_with?(auth_user, "@"),
        do: auth_user,
        else: "@#{auth_user}:#{server_name}"

    if auth_user_id != current_user_id do
      {:error, :forbidden}
    else
      case UserStore.get_user(current_user_id) do
        {:ok, user} ->
          if user.password_hash && Argon2.verify_pass(password, user.password_hash),
            do: :ok,
            else: {:error, :forbidden}

        _ ->
          {:error, :forbidden}
      end
    end
  end

  defp validate_ui_auth(_user_id, _auth), do: {:error, :forbidden}

  defp gen_session, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp device_to_map(device) do
    %{
      "device_id" => device.device_id,
      "display_name" => device.display_name,
      "last_seen_ip" => nil,
      "last_seen_ts" => nil
    }
  end
end
