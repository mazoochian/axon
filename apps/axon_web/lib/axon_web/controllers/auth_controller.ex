defmodule AxonWeb.AuthController do
  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  alias AxonCore.UserStore

  # POST /_matrix/client/v3/register
  def register(conn, params) do
    kind = params["kind"] || "user"

    if kind == "guest" do
      # Minimal guest registration
      localpart = "guest_#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}"

      with {:ok, result} <- UserStore.register(localpart, nil, server_name: server_name()) do
        conn |> put_status(200) |> json(%{
          "user_id" => result.user_id,
          "access_token" => result.access_token,
          "device_id" => result.device_id
        })
      end
    else
      username = params["username"]
      password = params["password"]

      unless username do
        conn |> put_status(400) |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "username required"})
      else
        opts = [
          server_name: server_name(),
          device_id: params["device_id"],
          display_name: params["initial_device_display_name"]
        ]

        with {:ok, result} <- UserStore.register(String.downcase(username), password, opts) do
          conn |> put_status(200) |> json(%{
            "user_id" => result.user_id,
            "access_token" => result.access_token,
            "device_id" => result.device_id
          })
        end
      end
    end
  end

  # POST /_matrix/client/v3/login
  def login(conn, params) do
    type = params["type"]

    case type do
      "m.login.password" ->
        identifier = params["identifier"] || %{}
        user = identifier["user"] || params["user"]
        password = params["password"]

        unless user && password do
          conn |> put_status(400) |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "user and password required"})
        else
          opts = [
            server_name: server_name(),
            device_id: params["device_id"],
            device_display_name: params["initial_device_display_name"]
          ]

          with {:ok, result} <- UserStore.login(String.downcase(user), password, opts) do
            json(conn, %{
              "user_id" => result.user_id,
              "access_token" => result.access_token,
              "device_id" => result.device_id,
              "home_server" => server_name()
            })
          end
        end

      _ ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_UNKNOWN", "error" => "Unsupported login type: #{type}"})
    end
  end

  # GET /_matrix/client/v3/login (list supported login types)
  def login_types(conn, _params) do
    json(conn, %{
      "flows" => [%{"type" => "m.login.password"}]
    })
  end

  # POST /_matrix/client/v3/logout
  def logout(conn, _params) do
    UserStore.logout(conn.assigns.current_token)
    json(conn, %{})
  end

  # POST /_matrix/client/v3/logout/all
  def logout_all(conn, _params) do
    UserStore.logout_all(conn.assigns.current_user_id)
    json(conn, %{})
  end

  # GET /_matrix/client/v3/account/whoami
  def whoami(conn, _params) do
    json(conn, %{
      "user_id" => conn.assigns.current_user_id,
      "device_id" => conn.assigns.current_device_id
    })
  end

  defp server_name, do: Application.fetch_env!(:axon_web, :server_name)
end
