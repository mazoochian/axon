defmodule AxonWeb.DeviceController do
  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  import Ecto.Query
  alias AxonCore.{Repo, UserStore}
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

  # DELETE /_matrix/client/v3/devices/:device_id
  # Requires User-Interactive Authentication
  def delete(conn, %{"device_id" => device_id} = params) do
    user_id = conn.assigns.current_user_id
    auth = params["auth"]

    cond do
      is_nil(auth) ->
        conn
        |> put_status(401)
        |> json(%{
          "session" => gen_session(),
          "flows" => [%{"stages" => ["m.login.password"]}],
          "params" => %{}
        })

      validate_ui_auth(user_id, auth) == :ok ->
        case Repo.get_by(Device, user_id: user_id, device_id: device_id) do
          nil ->
            {:error, :not_found}

          _device ->
            Repo.update_all(
              from(t in AccessToken,
                where: t.user_id == ^user_id and t.device_id == ^device_id),
              set: [valid: false]
            )
            Repo.delete_all(
              from(d in Device,
                where: d.user_id == ^user_id and d.device_id == ^device_id)
            )
            json(conn, %{})
        end

      true ->
        conn
        |> put_status(401)
        |> json(%{
          "session" => gen_session(),
          "flows" => [%{"stages" => ["m.login.password"]}],
          "params" => %{},
          "errcode" => "M_FORBIDDEN",
          "error" => "Invalid credentials"
        })
    end
  end

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
