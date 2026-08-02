defmodule AxonWeb.Plug.AuthenticateToken do
  @moduledoc """
  Extracts and validates the Bearer token, setting conn assigns.

  Also implements Application Service identity assertion: if the token
  matches a registered AS's `as_token` (checked first — the ETS lookup is
  O(registrations), cheap, and independent of the DB unlike the normal
  path), the request authenticates as that AS rather than as a normal
  user, and `?user_id=`/`?device_id=` query params let it act as any
  user/device in its own namespace (see `AxonWeb.AppService.Manager`).
  `conn.assigns.appservice` is set to the registration in this case, which
  downstream exclusive-namespace checks and `AxonWeb.Plug.RateLimit` use to
  recognize an AS-authenticated request.
  """

  import Plug.Conn
  require Logger
  alias AxonCore.UserStore
  alias AxonWeb.AppService.Manager

  def init(opts), do: opts

  def call(conn, _opts) do
    case extract_token(conn) do
      nil ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.json(%{
          "errcode" => "M_MISSING_TOKEN",
          "error" => "Missing access token"
        })
        |> halt()

      raw_token ->
        case Manager.verify_as_token(raw_token) do
          {:ok, registration} ->
            authenticate_as_appservice(conn, registration, raw_token)

          :error ->
            authenticate_as_user(conn, raw_token)
        end
    end
  end

  defp authenticate_as_user(conn, raw_token) do
    case UserStore.validate_token(raw_token) do
      {:ok, {user_id, device_id}} ->
        AxonSync.Presence.bump_activity(user_id)
        UserStore.touch_device(user_id, device_id, remote_ip(conn))
        Logger.metadata(user_id: user_id)

        conn
        |> assign(:current_user_id, user_id)
        |> assign(:current_device_id, device_id)
        |> assign(:current_token, raw_token)

      :error ->
        # Not one of our locally-issued tokens — if delegated OIDC auth
        # (MSC3861) is enabled, it may be a token from the external
        # Authorization Server; validate via introspection.
        case AxonWeb.Oidc.enabled?() and AxonWeb.Oidc.introspect(raw_token) do
          {:ok, {user_id, device_id}} ->
            AxonSync.Presence.bump_activity(user_id)
            UserStore.touch_device(user_id, device_id, remote_ip(conn))
            Logger.metadata(user_id: user_id)

            conn
            |> assign(:current_user_id, user_id)
            |> assign(:current_device_id, device_id)
            |> assign(:current_token, raw_token)

          _ ->
            conn
            |> put_status(401)
            |> Phoenix.Controller.json(%{
              "errcode" => "M_UNKNOWN_TOKEN",
              "error" => "Invalid access token"
            })
            |> halt()
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Application Service identity assertion (spec: "Identity assertion")
  # ---------------------------------------------------------------------------

  defp authenticate_as_appservice(conn, registration, raw_token) do
    sender_id = Manager.sender_user_id(registration)
    asserted_id = conn.query_params["user_id"] || sender_id

    if asserted_id != sender_id and not Manager.owns_user?(registration, asserted_id) do
      conn
      |> put_status(403)
      |> Phoenix.Controller.json(%{
        "errcode" => "M_FORBIDDEN",
        "error" => "Application service cannot masquerade as #{asserted_id}"
      })
      |> halt()
    else
      case ensure_appservice_user(asserted_id) do
        {:ok, _} ->
          finish_appservice_auth(conn, registration, raw_token, asserted_id)

        {:error, reason} ->
          conn
          |> put_status(500)
          |> Phoenix.Controller.json(%{
            "errcode" => "M_UNKNOWN",
            "error" => "Could not provision #{asserted_id}: #{inspect(reason)}"
          })
          |> halt()
      end
    end
  end

  defp finish_appservice_auth(conn, registration, raw_token, asserted_id) do
    case resolve_device(asserted_id, conn.query_params["device_id"]) do
      {:error, :unknown_device} ->
        conn
        |> put_status(400)
        |> Phoenix.Controller.json(%{
          "errcode" => "M_UNKNOWN_DEVICE",
          "error" => "Device does not belong to #{asserted_id}"
        })
        |> halt()

      {:ok, device_id} ->
        AxonSync.Presence.bump_activity(asserted_id)
        UserStore.touch_device(asserted_id, device_id, remote_ip(conn))
        Logger.metadata(user_id: asserted_id)

        conn
        |> assign(:current_user_id, asserted_id)
        |> assign(:current_device_id, device_id)
        |> assign(:current_token, raw_token)
        |> assign(:appservice, registration)
    end
  end

  @appservice_device_id "APPSERVICE"

  defp resolve_device(user_id, nil) do
    # No explicit ?device_id= — reuse (or lazily create) a stable default
    # device for this user rather than minting a fresh one per request.
    UserStore.ensure_device(user_id, @appservice_device_id, nil)
    {:ok, @appservice_device_id}
  end

  defp resolve_device(user_id, device_id) do
    # Spec (device masquerading, added v1.17): a device_id explicitly
    # requested via ?device_id= must already belong to the asserted user —
    # unlike the no-param case above, this doesn't lazily create one, since
    # the caller named a specific device it expects to already exist.
    if UserStore.device_exists?(user_id, device_id) do
      {:ok, device_id}
    else
      {:error, :unknown_device}
    end
  end

  # Registers a passwordless "ghost" user on first use if the asserted
  # identity doesn't exist yet (real bridges commonly assert as a ghost
  # they haven't explicitly called /register for) — mirrors
  # UserStore.authenticate_via_oidc/4's own lazy-provisioning shape.
  # Namespace ownership was already checked by the caller, so this doesn't
  # re-check exclusivity: an AS is always allowed to provision inside its
  # own claimed namespace.
  defp ensure_appservice_user(user_id) do
    case UserStore.get_user(user_id) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> register_ghost(user_id)
    end
  end

  defp register_ghost(user_id) do
    case String.split(String.trim_leading(user_id, "@"), ":", parts: 2) do
      [localpart, server_name] ->
        case UserStore.register(localpart, nil, server_name: server_name) do
          {:ok, result} -> {:ok, result}
          # Lost a race with a concurrent request provisioning the same ghost.
          {:error, :user_in_use} -> UserStore.get_user(user_id)
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :invalid_user_id}
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      _ -> conn.query_params["access_token"]
    end
  end

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
