defmodule AxonWeb.UIA do
  @moduledoc """
  User-Interactive Authentication for endpoints that must re-verify the
  caller (password change, deactivation, device deletion, cross-signing key
  replacement). Only `m.login.password` completes it; `m.login.dummy` is a
  registration-only stage and never proves who the caller is.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias AxonCore.UserStore

  @flows [%{"stages" => ["m.login.password"]}]

  def session, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  @doc """
  `:ok` when `auth` proves the caller is `user_id`; `{:error, :wrong_user}`
  when it names a different account; `{:error, :invalid}` otherwise.
  """
  def validate(user_id, %{"type" => "m.login.password"} = auth) do
    with {:ok, auth_user_id} <- auth_user_id(auth),
         :ok <- same_user(auth_user_id, user_id),
         password when is_binary(password) <- auth["password"],
         {:ok, %{password_hash: hash}} when is_binary(hash) <- UserStore.get_user(user_id),
         true <- Argon2.verify_pass(password, hash) do
      :ok
    else
      {:error, :wrong_user} = error -> error
      _ -> {:error, :invalid}
    end
  end

  def validate(_user_id, _auth), do: {:error, :invalid}

  @doc """
  Runs `on_success` once `auth` validates for `user_id`; otherwise responds
  with a 401 challenge (no or invalid auth) or 403 (auth for another user).
  """
  def authorize(conn, user_id, auth, on_success) do
    if is_nil(auth) do
      challenge(conn)
    else
      case validate(user_id, auth) do
        :ok ->
          on_success.()

        {:error, :wrong_user} ->
          conn
          |> put_status(403)
          |> json(%{
            "errcode" => "M_FORBIDDEN",
            "error" => "Auth user does not match the requester"
          })

        {:error, :invalid} ->
          challenge(conn, :invalid)
      end
    end
  end

  def challenge(conn, error \\ nil) do
    body = %{"session" => session(), "flows" => @flows, "params" => %{}, "completed" => []}

    body =
      if error,
        do: Map.merge(body, %{"errcode" => "M_FORBIDDEN", "error" => "Invalid credentials"}),
        else: body

    conn |> put_status(401) |> json(body)
  end

  defp auth_user_id(auth) do
    identifier =
      case auth["identifier"] do
        %{} = m -> m
        _ -> %{}
      end

    case identifier["user"] || auth["user"] do
      "@" <> _ = user_id ->
        {:ok, user_id}

      user when is_binary(user) and user != "" ->
        {:ok, "@#{String.downcase(user)}:#{AxonWeb.ServerName.get()}"}

      _ ->
        :error
    end
  end

  defp same_user(user_id, user_id), do: :ok
  defp same_user(_auth_user_id, _user_id), do: {:error, :wrong_user}
end
