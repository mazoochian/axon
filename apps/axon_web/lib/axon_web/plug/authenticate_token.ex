defmodule AxonWeb.Plug.AuthenticateToken do
  @moduledoc "Extracts and validates the Bearer token, setting conn assigns."

  import Plug.Conn
  require Logger
  alias AxonCore.UserStore

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
        case UserStore.validate_token(raw_token) do
          {:ok, {user_id, device_id}} ->
            finish_auth(conn, user_id, device_id, raw_token)

          :error ->
            authenticate_fallback(conn, raw_token)
        end
    end
  end

  # Not one of our locally-issued tokens — if delegated OIDC auth
  # (MSC3861) is enabled, it may be a token from the external
  # Authorization Server; validate via introspection.
  defp authenticate_fallback(conn, raw_token) do
    case AxonWeb.Oidc.enabled?() and AxonWeb.Oidc.introspect(raw_token) do
      {:ok, {user_id, device_id}} ->
        finish_auth(conn, user_id, device_id, raw_token)

      _ ->
        authenticate_appservice(conn, raw_token)
    end
  end

  # An application service's as_token, per the AS spec — acts as its own
  # sender_localpart user by default, or as any user matching one of its
  # registered namespaces via ?user_id= impersonation. The target user is
  # provisioned on first use (an appservice's ghost users never go
  # through /register): see AxonCore.UserStore.authenticate_via_appservice/3.
  defp authenticate_appservice(conn, raw_token) do
    with {:ok, registration} <- AxonWeb.AppService.Manager.verify_as_token(raw_token),
         target_user_id <- conn.query_params["user_id"] || sender_user_id(registration),
         true <- AxonWeb.AppService.Manager.owns_user?(registration, target_user_id),
         [_, localpart] <- Regex.run(~r/^@([^:]+):/, target_user_id),
         server_name <- AxonCore.MatrixId.server_name(target_user_id),
         device_id <- "APPSERVICE_" <> registration["id"],
         {:ok, {^target_user_id, ^device_id}} <-
           UserStore.authenticate_via_appservice(localpart, device_id, server_name) do
      finish_auth(conn, target_user_id, device_id, raw_token, is_appservice: true)
    else
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

  defp sender_user_id(registration) do
    "@#{registration["sender_localpart"]}:#{Application.get_env(:axon_web, :server_name, "localhost")}"
  end

  defp finish_auth(conn, user_id, device_id, raw_token, opts \\ []) do
    AxonSync.Presence.bump_activity(user_id)
    UserStore.touch_device(user_id, device_id, remote_ip(conn))
    Logger.metadata(user_id: user_id)

    conn
    |> assign(:current_user_id, user_id)
    |> assign(:current_device_id, device_id)
    |> assign(:current_token, raw_token)
    |> assign(:is_appservice, Keyword.get(opts, :is_appservice, false))
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      _ -> conn.query_params["access_token"]
    end
  end

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
