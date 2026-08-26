defmodule AxonWeb.AuthController do
  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  plug(AxonWeb.Plug.RateLimit, [bucket: :login] when action == :login)
  plug(AxonWeb.Plug.RateLimit, [bucket: :register] when action == :register)

  # The Synapse-compatible shared-secret admin bootstrap: unauthenticated by
  # design (the HMAC MAC *is* the credential), so an IP limit is the only
  # thing standing between an attacker and unlimited offline-style MAC
  # guessing against a live server. Nonce issuance is limited too — it's the
  # first half of the same flow.
  plug(
    AxonWeb.Plug.RateLimit,
    [bucket: :admin_register] when action in [:synapse_nonce, :synapse_register]
  )

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{UserStore, Repo}

  # POST /_matrix/client/v3/register
  def register(conn, params) do
    cond do
      AxonWeb.Oidc.enabled?() ->
        oidc_disabled_response(
          conn,
          "Registration is handled by the configured Authorization Server"
        )

      not registration_enabled?() ->
        registration_disabled_response(conn)

      true ->
        do_register(conn, params)
    end
  end

  defp do_register(conn, params) do
    kind = params["kind"] || "user"

    if kind == "guest" do
      localpart = "guest_#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}"

      opts = [
        server_name: server_name(),
        is_guest: true,
        refresh_token: refresh_requested?(params)
      ]

      with {:ok, result} <- UserStore.register(localpart, nil, opts) do
        conn |> put_status(200) |> json(login_response(result))
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
                display_name: username,
                refresh_token: refresh_requested?(params)
              ]

              with {:ok, result} <- UserStore.register(String.downcase(username), password, opts) do
                conn |> put_status(200) |> json(login_response(result))
              end
            end
          end
        end
      end
    end
  end

  # GET /_matrix/client/v3/register/available
  def register_available(conn, params) do
    if not registration_enabled?() do
      registration_disabled_response(conn)
    else
      do_register_available(conn, params)
    end
  end

  defp do_register_available(conn, params) do
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

          if logout_devices do
            UserStore.logout_all(user_id, conn.assigns.current_token)

            # Pushers on the device making this request survive (that device
            # isn't being logged out); pushers registered under any other
            # device — now logged out — are deleted along with it.
            Repo.delete_all(
              from(p in "pushers",
                where: p.user_id == ^user_id and p.device_id != ^conn.assigns.current_device_id
              )
            )
          end

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
    UserStore.deactivate(user_id)
    json(conn, %{"id_server_unbind_result" => "success"})
  end

  # Shared secret for the Synapse-compatible admin bootstrap endpoints
  # below. Read at request time from `:axon_web, :registration_shared_secret`
  # — sourced from REGISTRATION_SHARED_SECRET in config/runtime.exs (prod),
  # and from a fixed convenience value in config/dev.exs and config/test.exs
  # (a throwaway local database is not worth per-run key management, and
  # Complement's harness hardcodes "complement" as its own homeserver's
  # registration_shared_secret).
  #
  # This used to be a compiled-in literal with no override, which meant every
  # deployment shipped the *same* publicly-known secret — i.e. anyone could
  # mint a full admin account on any Axon server. There is deliberately no
  # fallback now: unset in prod and both endpoints below behave as if they
  # don't exist (404 M_UNRECOGNIZED, same shape AxonWeb.Router gives any
  # unrouted path), rather than degrading to a guessable default.
  defp synapse_shared_secret do
    case Application.get_env(:axon_web, :registration_shared_secret) do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> nil
    end
  end

  defp shared_secret_disabled_response(conn) do
    conn
    |> put_status(404)
    |> json(%{"errcode" => "M_UNRECOGNIZED", "error" => "Unrecognized request"})
  end

  # GET /_synapse/admin/v1/register
  def synapse_nonce(conn, _params) do
    if is_nil(synapse_shared_secret()) do
      shared_secret_disabled_response(conn)
    else
      nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      json(conn, %{"nonce" => nonce})
    end
  end

  # POST /_synapse/admin/v1/register
  def synapse_register(conn, params) do
    if is_nil(synapse_shared_secret()) do
      shared_secret_disabled_response(conn)
    else
      do_synapse_register(conn, params)
    end
  end

  defp do_synapse_register(conn, params) do
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

      not valid_synapse_mac?(mac, nonce, username, password, is_admin) ->
        conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Invalid MAC"})

      true ->
        opts = [server_name: server_name(), admin: is_admin]

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
            device_display_name: params["initial_device_display_name"],
            refresh_token: refresh_requested?(params)
          ]

          with {:ok, result} <- UserStore.login(String.downcase(user), password, opts) do
            json(conn, login_response(result, %{"home_server" => server_name()}))
          end
        end

      _ ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_UNKNOWN", "error" => "Unsupported login type: #{type}"})
    end
  end

  # POST /_matrix/client/v3/refresh — stable Matrix spec (formerly
  # MSC2918). Unauthenticated (no Bearer token): the refresh_token in the
  # body *is* the credential. See AxonCore.UserStore.refresh/1 for the
  # rotation semantics and error-code sourcing (Synapse's auth.py).
  def refresh(conn, params) do
    case params["refresh_token"] do
      raw when is_binary(raw) and raw != "" ->
        case UserStore.refresh(raw) do
          {:ok, result} ->
            json(conn, %{
              "access_token" => result.access_token,
              "refresh_token" => result.refresh_token,
              "expires_in_ms" => result.expires_in_ms
            })

          {:error, :unknown_token} ->
            conn
            |> put_status(401)
            |> json(%{"errcode" => "M_UNKNOWN_TOKEN", "error" => "Invalid refresh token"})

          {:error, reason} when reason in [:already_used, :refresh_expired] ->
            conn
            |> put_status(403)
            |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Refresh token is no longer valid"})

          {:error, :internal} ->
            conn
            |> put_status(500)
            |> json(%{"errcode" => "M_UNKNOWN", "error" => "Internal server error"})
        end

      _ ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "refresh_token required"})
    end
  end

  # `refresh_token: true` in a login/register request body — per spec this
  # opts in to also receiving a refresh_token and a real access_token
  # expiry. Anything else (omitted, false, or a non-boolean) leaves the
  # pre-existing never-expiring-single-token behavior untouched.
  defp refresh_requested?(params), do: params["refresh_token"] == true

  defp login_response(result, extra \\ %{}) do
    %{
      "user_id" => result.user_id,
      "access_token" => result.access_token,
      "device_id" => result.device_id
    }
    |> Map.merge(extra)
    |> maybe_put("expires_in_ms", result[:expires_in_ms])
    |> maybe_put("refresh_token", result[:refresh_token])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # GET /_matrix/client/v3/login (list supported login types)
  def login_types(conn, _params) do
    flows = if AxonWeb.Oidc.enabled?(), do: [], else: [%{"type" => "m.login.password"}]
    json(conn, %{"flows" => flows})
  end

  defp oidc_disabled_response(conn, message) do
    conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => message})
  end

  # config :axon_web, :registration, enabled: ... — off by default in prod
  # (Synapse's own enable_registration: false safe default), on in dev/test.
  # See config/config.exs, config/dev.exs, config/test.exs, config/runtime.exs.
  defp registration_enabled?, do: Application.fetch_env!(:axon_web, :registration)[:enabled]

  # Same status/errcode/message Synapse returns from both RegisterRestServlet
  # and UsernameAvailabilityRestServlet when enable_registration is false.
  defp registration_disabled_response(conn) do
    conn
    |> put_status(403)
    |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Registration has been disabled"})
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

  # POST /_matrix/client/v3/user/:user_id/openid/request_token
  #
  # Mints a short-lived OpenID token the caller can hand to a third party
  # (an identity server, typically) to prove their Matrix user ID — the
  # third party verifies it via
  # `GET /_matrix/federation/v1/openid/userinfo` (see
  # `AxonWeb.FederationController.openid_userinfo/2`). Per spec, only the
  # user themself may request a token for their own `user_id`.
  def openid_request_token(conn, %{"user_id" => user_id}) do
    if user_id != conn.assigns.current_user_id do
      conn
      |> put_status(403)
      |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Cannot request an OpenID token for another user"})
    else
      {token, expires_in} = AxonWeb.OpenidTokens.issue(user_id)

      json(conn, %{
        "access_token" => token,
        "token_type" => "Bearer",
        "matrix_server_name" => server_name(),
        "expires_in" => expires_in
      })
    end
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

  # Constant-time comparison (Plug.Crypto.secure_compare/2) rather than `==`,
  # so a MAC guess can't be refined a byte at a time off the response timing.
  defp valid_synapse_mac?(mac, nonce, username, password, is_admin) when is_binary(mac) do
    expected = compute_synapse_mac(nonce, username, password, is_admin)
    byte_size(mac) == byte_size(expected) and Plug.Crypto.secure_compare(mac, expected)
  end

  defp valid_synapse_mac?(_mac, _nonce, _username, _password, _is_admin), do: false

  defp compute_synapse_mac(nonce, username, password, is_admin) do
    admin_str = if is_admin, do: "admin", else: "notadmin"
    data = nonce <> "\x00" <> username <> "\x00" <> password <> "\x00" <> admin_str
    :crypto.mac(:hmac, :sha, synapse_shared_secret(), data) |> Base.encode16(case: :lower)
  end
end
