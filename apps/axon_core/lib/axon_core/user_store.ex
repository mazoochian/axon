defmodule AxonCore.UserStore do
  @moduledoc "Registration, authentication, and profile management."

  import Ecto.Query
  alias AxonCore.Repo
  alias AxonCore.Schema.{User, UserProfile, Device, AccessToken}

  @token_bytes 32

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  @doc """
  Registers a new local user.

  Returns `{:ok, %{user_id, access_token, device_id}}` or `{:error, reason}`.
  """
  def register(localpart, password, opts \\ []) do
    server_name = opts[:server_name] || Application.get_env(:axon_web, :server_name, "localhost")
    device_id = opts[:device_id] || generate_device_id()
    display_name = opts[:display_name]

    user_id = "@#{localpart}:#{server_name}"
    password_hash = if password, do: Argon2.hash_pwd_salt(password)

    result =
      try do
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user,
          User.changeset(%User{}, %{user_id: user_id, localpart: localpart, password_hash: password_hash})
        )
        |> Ecto.Multi.insert(:profile, fn %{user: user} ->
          UserProfile.changeset(%UserProfile{user_id: user.user_id}, %{displayname: display_name || localpart})
        end)
        |> Ecto.Multi.insert(:device, fn %{user: user} ->
          Device.changeset(%Device{}, %{user_id: user.user_id, device_id: device_id})
        end)
        |> Ecto.Multi.run(:token, fn _repo, %{user: user} ->
          issue_token(user.user_id, device_id)
        end)
        |> Repo.transaction()
      rescue
        Ecto.ConstraintError -> {:error, :constraint}
      end

    case result do
      {:ok, %{user: user, token: {raw_token, _}}} ->
        {:ok, %{user_id: user.user_id, access_token: raw_token, device_id: device_id}}

      {:error, :user, changeset, _} ->
        if Keyword.has_key?(changeset.errors, :localpart),
          do: {:error, :user_in_use},
          else: {:error, :invalid_input}

      {:error, :constraint} ->
        {:error, :user_in_use}

      {:error, _, _, _} ->
        {:error, :internal}
    end
  end

  # ---------------------------------------------------------------------------
  # Login
  # ---------------------------------------------------------------------------

  @doc """
  Authenticates a user by password.

  Returns `{:ok, %{user_id, access_token, device_id}}` or `{:error, :forbidden}`.
  """
  def login(localpart_or_user_id, password, opts \\ []) do
    server_name = opts[:server_name] || Application.get_env(:axon_web, :server_name, "localhost")
    device_id = opts[:device_id] || generate_device_id()
    display_name = opts[:device_display_name]

    user_id =
      if String.starts_with?(localpart_or_user_id, "@"),
        do: localpart_or_user_id,
        else: "@#{localpart_or_user_id}:#{server_name}"

    with {:ok, user} <- fetch_user(user_id),
         true <- not user.deactivated,
         true <- Argon2.verify_pass(password, user.password_hash) do
      ensure_device(user.user_id, device_id, display_name)

      case issue_token(user.user_id, device_id) do
        {:ok, {raw_token, _}} ->
          {:ok, %{user_id: user.user_id, access_token: raw_token, device_id: device_id}}

        _ ->
          {:error, :internal}
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  # ---------------------------------------------------------------------------
  # Token management
  # ---------------------------------------------------------------------------

  @doc "Validates a raw Bearer token. Returns `{:ok, {user_id, device_id}}` or `:error`."
  def validate_token(raw_token) do
    hash = token_hash(raw_token)

    case Repo.one(
           from t in AccessToken,
             where: t.token_hash == ^hash and t.valid == true,
             select: {t.user_id, t.device_id}
         ) do
      nil -> :error
      result -> {:ok, result}
    end
  end

  @doc "Invalidates a single token and deletes the associated device."
  def logout(raw_token) do
    hash = token_hash(raw_token)
    case Repo.one(from t in AccessToken, where: t.token_hash == ^hash and t.valid == true, select: {t.user_id, t.device_id}) do
      nil ->
        :ok
      {user_id, device_id} ->
        Repo.update_all(from(t in AccessToken, where: t.user_id == ^user_id and t.device_id == ^device_id), set: [valid: false])
        Repo.delete_all(from(d in Device, where: d.user_id == ^user_id and d.device_id == ^device_id))
        :ok
    end
  end

  @doc "Invalidates all tokens for a user (optionally scoped to a device)."
  def logout_all(user_id, except_token \\ nil) do
    q = from t in AccessToken, where: t.user_id == ^user_id and t.valid == true

    q =
      if except_token do
        hash = token_hash(except_token)
        from t in q, where: t.token_hash != ^hash
      else
        q
      end

    Repo.update_all(q, set: [valid: false])
    :ok
  end

  # ---------------------------------------------------------------------------
  # Profile
  # ---------------------------------------------------------------------------

  def get_profile(user_id) do
    case Repo.get(UserProfile, user_id) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  def update_profile(user_id, attrs) do
    with {:ok, profile} <- get_profile(user_id) do
      profile
      |> UserProfile.changeset(attrs)
      |> Repo.update()
    end
  end

  def get_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  defp issue_token(user_id, device_id) do
    raw = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
    hash = token_hash(raw)

    case Repo.insert(%AccessToken{token_hash: hash, user_id: user_id, device_id: device_id}) do
      {:ok, token} -> {:ok, {raw, token}}
      error -> error
    end
  end

  defp ensure_device(user_id, device_id, display_name) do
    case Repo.get_by(Device, user_id: user_id, device_id: device_id) do
      nil ->
        Repo.insert(%Device{
          user_id: user_id,
          device_id: device_id,
          display_name: display_name
        })

      device ->
        {:ok, device}
    end
  end

  defp token_hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp generate_device_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false) |> String.upcase()
  end
end
