defmodule AxonWeb.DeviceController do
  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  plug(
    AxonWeb.Plug.RateLimit,
    [bucket: :ui_auth, key_by: :user] when action in [:delete, :delete_devices]
  )

  import Ecto.Query
  alias AxonCore.Repo
  alias AxonCore.Schema.Device
  alias AxonWeb.{Devices, UIA}

  # GET /_matrix/client/v3/devices
  def index(conn, _params) do
    user_id = conn.assigns.current_user_id
    devices = Repo.all(from(d in Device, where: d.user_id == ^user_id))
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
  # Requires password UIA, bypassed when delegated OIDC auth (MSC3861) is
  # enabled since a valid Authorization-Server-issued token is proof enough.
  def delete_devices(conn, params) do
    user_id = conn.assigns.current_user_id

    case params["devices"] do
      device_ids when is_list(device_ids) ->
        if Enum.all?(device_ids, &is_binary/1) do
          with_ui_auth(conn, user_id, params["auth"], fn ->
            Devices.remove(user_id, device_ids)
            json(conn, %{})
          end)
        else
          bad_param(conn, "M_INVALID_PARAM", "devices must be an array of device IDs")
        end

      nil ->
        bad_param(conn, "M_MISSING_PARAM", "devices is required")

      _ ->
        bad_param(conn, "M_INVALID_PARAM", "devices must be an array of device IDs")
    end
  end

  # DELETE /_matrix/client/v3/devices/:device_id
  def delete(conn, %{"device_id" => device_id} = params) do
    user_id = conn.assigns.current_user_id

    with_ui_auth(conn, user_id, params["auth"], fn ->
      case Repo.get_by(Device, user_id: user_id, device_id: device_id) do
        nil ->
          {:error, :not_found}

        _device ->
          Devices.remove(user_id, [device_id])
          json(conn, %{})
      end
    end)
  end

  defp with_ui_auth(conn, user_id, auth, fun) do
    if AxonWeb.Oidc.enabled?(), do: fun.(), else: UIA.authorize(conn, user_id, auth, fun)
  end

  defp bad_param(conn, errcode, error) do
    conn |> put_status(400) |> json(%{"errcode" => errcode, "error" => error})
  end

  defp device_to_map(device) do
    %{
      "device_id" => device.device_id,
      "display_name" => device.display_name,
      "last_seen_ip" => device.last_seen_ip,
      "last_seen_ts" => device.last_seen_ts
    }
  end
end
