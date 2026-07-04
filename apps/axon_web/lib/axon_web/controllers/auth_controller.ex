defmodule AxonWeb.AuthController do
  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{UserStore, Repo}

  # POST /_matrix/client/v3/register
  def register(conn, params) do
    if AxonWeb.Oidc.enabled?() do
      oidc_disabled_response(
        conn,
        "Registration is handled by the configured Authorization Server"
      )
    else
      do_register(conn, params)
    end
  end

  defp do_register(conn, params) do
    kind = params["kind"] || "user"

    if kind == "guest" do
      localpart = "guest_#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}"

      with {:ok, result} <-
             UserStore.register(localpart, nil, server_name: server_name(), is_guest: true) do
        conn
        |> put_status(200)
        |> json(%{
          "user_id" => result.user_id,
          "access_token" => result.access_token,
          "device_id" => result.device_id
        })
      end
    else
      username = params["username"]
      password = params["password"]

      if username && !valid_localpart?(username) do
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_INVALID_USERNAME", "error" => "Invalid username"})
      else
        user_id = username && "@#{String.downcase(username)}:#{server_name()}"

        if user_id && user_exists?(user_id) do
          conn
          |> put_status(400)
          |> json(%{"errcode" => "M_USER_IN_USE", "error" => "Username already taken"})
        else
          auth = params["auth"]

          if is_nil(auth) do
            conn
            |> put_status(401)
            |> json(%{
              "flows" => [%{"stages" => ["m.login.dummy"]}],
              "session" => gen_session(),
              "params" => %{}
            })
          else
            unless username do
              conn
              |> put_status(400)
              |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "username required"})
            else
              opts = [
                server_name: server_name(),
                device_id: params["device_id"],
                display_name: username
              ]

              with {:ok, result} <- UserStore.register(String.downcase(username), password, opts) do
                conn
                |> put_status(200)
                |> json(%{
                  "user_id" => result.user_id,
                  "access_token" => result.access_token,
                  "device_id" => result.device_id
                })
              end
            end
          end
        end
      end
    end
  end

  # GET /_matrix/client/v3/register/available
  def register_available(conn, params) do
    username = params["username"]

    cond do
      is_nil(username) ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "username required"})

      !valid_localpart?(username) ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_INVALID_USERNAME", "error" => "Invalid username"})

      user_exists?("@#{String.downcase(username)}:#{server_name()}") ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_USER_IN_USE", "error" => "Username already taken"})

      true ->
        json(conn, %{"available" => true})
    end
  end

  # POST /_matrix/client/v3/account/password
  def change_password(conn, params) do
    if AxonWeb.Oidc.enabled?() do
      oidc_disabled_response(
        conn,
        "Password is managed by the configured Authorization Server"
      )
    else
      do_change_password(conn, params)
    end
  end

  defp do_change_password(conn, params) do
    user_id = conn.assigns.current_user_id
    new_password = params["new_password"]
    auth = params["auth"]
    logout_devices = Map.get(params, "logout_devices", true)

    if is_nil(new_password) do
      conn
      |> put_status(400)
      |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "new_password required"})
    else
      if is_nil(auth) do
        conn
        |> put_status(401)
        |> json(%{
          "session" => gen_session(),
          "flows" => [%{"stages" => ["m.login.password"]}],
          "params" => %{}
        })
      else
        if validate_ui_auth(user_id, auth) == :ok do
          new_hash = Argon2.hash_pwd_salt(new_password)

          Repo.update_all(from(u in "users", where: u.user_id == ^user_id),
            set: [password_hash: new_hash]
          )

          if logout_devices, do: UserStore.logout_all(user_id, conn.assigns.current_token)
          json(conn, %{})
        else
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
    end
  end

  # POST /_matrix/client/v3/account/deactivate
  # Requires User-Interactive Authentication — bypassed when delegated OIDC
  # auth (MSC3861) is enabled, since a valid, currently-active
  # Authorization-Server-issued token is proof enough.
  def deactivate(conn, params) do
    user_id = conn.assigns.current_user_id
    auth = params["auth"]

    cond do
      AxonWeb.Oidc.enabled?() ->
        do_deactivate(conn, user_id)

      is_nil(auth) ->
        conn
        |> put_status(401)
        |> json(%{
          "session" => gen_session(),
          "flows" => [%{"stages" => ["m.login.password"]}],
          "params" => %{}
        })

      validate_ui_auth(user_id, auth) == :ok ->
        do_deactivate(conn, user_id)

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

  defp do_deactivate(conn, user_id) do
    Repo.update_all(from(u in "users", where: u.user_id == ^user_id),
      set: [deactivated: true]
    )

    UserStore.logout_all(user_id)
    json(conn, %{"id_server_unbind_result" => "success"})
  end

  @synapse_shared_secret "complement"

  # GET /_synapse/admin/v1/register
  def synapse_nonce(conn, _params) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    json(conn, %{"nonce" => nonce})
  end

  # POST /_synapse/admin/v1/register
  def synapse_register(conn, params) do
    username = params["username"]
    password = params["password"] || ""
    nonce = params["nonce"] || ""
    mac = params["mac"]
    is_admin = params["admin"] == true

    cond do
      is_nil(username) || !valid_localpart?(username) ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_INVALID_USERNAME", "error" => "Invalid username"})

      mac != compute_synapse_mac(nonce, username, password, is_admin) ->
        conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Invalid MAC"})

      true ->
        opts = [server_name: server_name()]

        case UserStore.register(String.downcase(username), password, opts) do
          {:ok, result} ->
            json(conn, %{
              "user_id" => result.user_id,
              "access_token" => result.access_token,
              "device_id" => result.device_id,
              "home_server" => server_name()
            })

          {:error, :user_in_use} ->
            conn
            |> put_status(400)
            |> json(%{"errcode" => "M_USER_IN_USE", "error" => "Username already taken"})

          {:error, _} ->
            conn
            |> put_status(500)
            |> json(%{"errcode" => "M_UNKNOWN", "error" => "Internal error"})
        end
    end
  end

  # POST /_matrix/client/v3/login
  def login(conn, params) do
    if AxonWeb.Oidc.enabled?() do
      oidc_disabled_response(conn, "Login is handled by the configured Authorization Server")
    else
      do_login(conn, params)
    end
  end

  defp do_login(conn, params) do
    type = params["type"]

    case type do
      "m.login.password" ->
        identifier = params["identifier"] || %{}
        user = identifier["user"] || params["user"]
        password = params["password"]

        unless user && password do
          conn
          |> put_status(400)
          |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "user and password required"})
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
    flows = if AxonWeb.Oidc.enabled?(), do: [], else: [%{"type" => "m.login.password"}]
    json(conn, %{"flows" => flows})
  end

  defp oidc_disabled_response(conn, message) do
    conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => message})
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

  defp valid_localpart?(localpart), do: Regex.match?(~r/^[a-z0-9._\-=\/]+$/i, localpart)

  defp user_exists?(user_id) do
    Repo.one(from(u in "users", where: u.user_id == ^user_id, select: u.user_id)) != nil
  end

  defp gen_session, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp validate_ui_auth(current_user_id, %{"type" => "m.login.password"} = auth) do
    identifier = auth["identifier"] || %{}
    auth_user = identifier["user"] || auth["user"]
    password = auth["password"]

    auth_user_id =
      if auth_user && String.starts_with?(auth_user, "@"),
        do: auth_user,
        else: "@#{auth_user}:#{server_name()}"

    if auth_user_id != current_user_id do
      :error
    else
      case UserStore.get_user(current_user_id) do
        {:ok, user} ->
          if user.password_hash && Argon2.verify_pass(password, user.password_hash),
            do: :ok,
            else: :error

        _ ->
          :error
      end
    end
  end

  defp validate_ui_auth(_user_id, _auth), do: :error

  defp compute_synapse_mac(nonce, username, password, is_admin) do
    admin_str = if is_admin, do: "admin", else: "notadmin"
    data = nonce <> "\x00" <> username <> "\x00" <> password <> "\x00" <> admin_str
    :crypto.mac(:hmac, :sha, @synapse_shared_secret, data) |> Base.encode16(case: :lower)
  end
end
