defmodule AxonCore.UserStore do
  @moduledoc "Registration, authentication, and profile management."

  import Ecto.Query
  alias AxonCore.{KeyStore, Repo}
  alias AxonCore.Schema.{User, UserProfile, Device, AccessToken, RefreshToken}

  @token_bytes 32

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  @doc """
  Registers a new local user.

  `opts[:refresh_token]` — when truthy, also issues a refresh token and
  gives the access token a real expiry (`expires_in_ms` in the result),
  per the stable Matrix spec (formerly MSC2918). Omitted/falsy keeps the
  pre-existing behavior exactly: a single never-expiring access token and
  no `refresh_token`/`expires_in_ms` keys in the result.

  Returns `{:ok, %{user_id, access_token, device_id, expires_in_ms?, refresh_token?}}`
  or `{:error, reason}`.
  """
  def register(localpart, password, opts \\ []) do
    server_name = opts[:server_name] || Application.get_env(:axon_web, :server_name, "localhost")
    device_id = opts[:device_id] || generate_device_id()
    display_name = opts[:display_name]
    refresh? = opts[:refresh_token] || false

    user_id = "@#{localpart}:#{server_name}"
    password_hash = if password, do: Argon2.hash_pwd_salt(password)
    is_guest = opts[:is_guest] || false
    is_admin = opts[:admin] || false

    result =
      try do
        Ecto.Multi.new()
        |> Ecto.Multi.insert(
          :user,
          User.changeset(%User{}, %{
            user_id: user_id,
            localpart: localpart,
            password_hash: password_hash,
            is_guest: is_guest,
            admin: is_admin
          })
        )
        |> Ecto.Multi.insert(:profile, fn %{user: user} ->
          UserProfile.changeset(%UserProfile{user_id: user.user_id}, %{
            displayname: display_name || localpart
          })
        end)
        |> Ecto.Multi.insert(:device, fn %{user: user} ->
          Device.changeset(%Device{}, %{user_id: user.user_id, device_id: device_id})
        end)
        |> Ecto.Multi.run(:tokens, fn _repo, %{user: user} ->
          issue_login_tokens(user.user_id, device_id, refresh?)
        end)
        |> Repo.transaction()
      rescue
        Ecto.ConstraintError -> {:error, :constraint}
      end

    case result do
      {:ok, %{user: user, tokens: tokens}} ->
        {:ok, Map.merge(%{user_id: user.user_id, device_id: device_id}, tokens)}

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

  `opts[:refresh_token]` — see `register/3`; same effect on the result
  shape (adds `expires_in_ms`/`refresh_token`, gives the access token a
  real expiry) and same no-op when omitted/falsy.

  Returns `{:ok, %{user_id, access_token, device_id, expires_in_ms?, refresh_token?}}`
  or `{:error, :forbidden}`.
  """
  def login(localpart_or_user_id, password, opts \\ []) do
    server_name = opts[:server_name] || Application.get_env(:axon_web, :server_name, "localhost")
    device_id = opts[:device_id] || generate_device_id()
    display_name = opts[:device_display_name]
    refresh? = opts[:refresh_token] || false

    user_id =
      if String.starts_with?(localpart_or_user_id, "@"),
        do: localpart_or_user_id,
        else: "@#{localpart_or_user_id}:#{server_name}"

    with {:ok, user} <- fetch_user(user_id),
         true <- not user.deactivated,
         true <- Argon2.verify_pass(password, user.password_hash) do
      ensure_device(user.user_id, device_id, display_name)

      case issue_login_tokens(user.user_id, device_id, refresh?) do
        {:ok, tokens} ->
          {:ok, Map.merge(%{user_id: user.user_id, device_id: device_id}, tokens)}

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

  @doc "Whether `user_id` registered as a guest account (kind: \"guest\")."
  def guest?(user_id) do
    Repo.one(from(u in User, where: u.user_id == ^user_id, select: u.is_guest)) || false
  end

  @doc """
  Deactivates a user: marks the account deactivated and invalidates every
  access token, local (self-service `/account/deactivate`) or admin-initiated.
  """
  def deactivate(user_id) do
    Repo.update_all(from(u in User, where: u.user_id == ^user_id), set: [deactivated: true])
    logout_all(user_id)
    :ok
  end

  @doc "Sets or clears a user's shadow-ban flag (admin API)."
  def set_shadow_banned(user_id, banned?) when is_boolean(banned?) do
    Repo.update_all(from(u in User, where: u.user_id == ^user_id), set: [shadow_banned: banned?])
    :ok
  end

  @doc "Whether `user_id` is currently shadow-banned."
  def shadow_banned?(user_id) do
    Repo.one(from(u in User, where: u.user_id == ^user_id, select: u.shadow_banned)) || false
  end

  @doc """
  Validates a raw Bearer token. Returns `{:ok, {user_id, device_id}}` or
  `:error` — the latter both when the token doesn't exist/was logged out
  *and* when it's a real, `valid: true` token whose `expires_at_ms` has
  passed, so an expired refreshable access token fails exactly the same
  way an unknown one does (and falls through to the same OIDC/appservice
  fallback chain in `AxonWeb.Plug.AuthenticateToken`, ending in the same
  401 M_UNKNOWN_TOKEN response).
  """
  def validate_token(raw_token) do
    hash = token_hash(raw_token)
    now = System.os_time(:millisecond)

    case Repo.one(
           from(t in AccessToken,
             where:
               t.token_hash == ^hash and t.valid == true and
                 (is_nil(t.expires_at_ms) or t.expires_at_ms > ^now),
             select: {t.user_id, t.device_id}
           )
         ) do
      nil -> :error
      result -> {:ok, result}
    end
  end

  @doc """
  Invalidates a single token and deletes the associated device (and its
  key material) — also drops every refresh token issued for that
  user_id + device_id, so a still-valid refresh token can't mint fresh
  access tokens for a device that was just logged out.
  """
  def logout(raw_token) do
    hash = token_hash(raw_token)

    case Repo.one(
           from(t in AccessToken,
             where: t.token_hash == ^hash and t.valid == true,
             select: {t.user_id, t.device_id}
           )
         ) do
      nil ->
        :ok

      {user_id, device_id} ->
        Repo.update_all(
          from(t in AccessToken, where: t.user_id == ^user_id and t.device_id == ^device_id),
          set: [valid: false]
        )

        Repo.delete_all(
          from(r in RefreshToken, where: r.user_id == ^user_id and r.device_id == ^device_id)
        )

        # Purges device_keys/one_time_keys/fallback_keys too -- not just the
        # `devices` row -- so a logged-out session's identity keys don't keep
        # getting served by /keys/query forever.
        KeyStore.purge_device(user_id, device_id)
        KeyStore.record_device_list_update(user_id)

        :ok
    end
  end

  @doc """
  Invalidates all tokens for a user (optionally sparing the device that
  `except_token` belongs to) — also drops every refresh token for the
  user, other than ones belonging to the spared device, for the same
  reason `logout/1` does.
  """
  def logout_all(user_id, except_token \\ nil) do
    except_hash = except_token && token_hash(except_token)

    except_device_id =
      except_hash &&
        Repo.one(from(t in AccessToken, where: t.token_hash == ^except_hash, select: t.device_id))

    q = from(t in AccessToken, where: t.user_id == ^user_id and t.valid == true)
    q = if except_hash, do: from(t in q, where: t.token_hash != ^except_hash), else: q
    Repo.update_all(q, set: [valid: false])

    rq = from(r in RefreshToken, where: r.user_id == ^user_id)
    rq = if except_device_id, do: from(r in rq, where: r.device_id != ^except_device_id), else: rq
    Repo.delete_all(rq)

    :ok
  end

  @doc """
  Exchanges a refresh token for a new access token + refresh token pair,
  per the stable Matrix spec (formerly MSC2918): single-use rotation, the
  old refresh token stops working the instant this succeeds, and the new
  pair carries the same user_id/device_id forward (this refreshes an
  existing login session, it doesn't start a new one).

  Returns `{:ok, %{access_token, expires_in_ms, refresh_token}}`, or
  `{:error, reason}` with `reason` one of:

    * `:unknown_token` — no such refresh token was ever issued (or it's
      garbage). Matches Synapse's `auth.py` `refresh_token/3`: an
      unrecognized/malformed token is `401 M_UNKNOWN_TOKEN`.
    * `:already_used` or `:refresh_expired` — the token existed but is no
      longer usable. Synapse returns `403 M_FORBIDDEN` for both of these
      (distinct from the 401 above) — see the same source function.
  """
  def refresh(raw_refresh_token) do
    hash = token_hash(raw_refresh_token)
    now = System.os_time(:millisecond)

    case Repo.get_by(RefreshToken, token_hash: hash) do
      nil ->
        {:error, :unknown_token}

      %RefreshToken{next_token_id: next_id} when not is_nil(next_id) ->
        {:error, :already_used}

      %RefreshToken{expiry_ts: expiry_ts} when not is_nil(expiry_ts) and expiry_ts < now ->
        {:error, :refresh_expired}

      %RefreshToken{} = token ->
        do_refresh(token)
    end
  end

  defp do_refresh(old_token) do
    now = System.os_time(:millisecond)
    raw_access = generate_raw_token()
    raw_refresh = generate_raw_token()
    access_expires_at = now + access_token_lifetime_ms()
    refresh_lifetime_ms = refresh_token_lifetime_ms()
    refresh_expires_at = refresh_lifetime_ms && now + refresh_lifetime_ms

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :new_refresh,
        RefreshToken.changeset(%RefreshToken{}, %{
          token_hash: token_hash(raw_refresh),
          user_id: old_token.user_id,
          device_id: old_token.device_id,
          expiry_ts: refresh_expires_at,
          ultimate_session_expiry_ts: old_token.ultimate_session_expiry_ts
        })
      )
      |> Ecto.Multi.insert(
        :new_access,
        AccessToken.changeset(%AccessToken{}, %{
          token_hash: token_hash(raw_access),
          user_id: old_token.user_id,
          device_id: old_token.device_id,
          expires_at_ms: access_expires_at
        })
      )
      |> Ecto.Multi.run(:rotate, fn repo, %{new_refresh: new_refresh} ->
        # Guarded on `next_token_id IS NULL` (not just the read above) so
        # two concurrent refreshes of the same token can't both win: only
        # one `update_all` here actually flips a row, the other affects
        # zero rows and is treated as a late "already used".
        {count, _} =
          repo.update_all(
            from(r in RefreshToken, where: r.id == ^old_token.id and is_nil(r.next_token_id)),
            set: [next_token_id: new_refresh.id]
          )

        if count == 1, do: {:ok, count}, else: {:error, :already_used}
      end)
      |> Repo.transaction()

    case result do
      {:ok, _} ->
        {:ok,
         %{
           access_token: raw_access,
           expires_in_ms: access_expires_at - now,
           refresh_token: raw_refresh
         }}

      {:error, :rotate, :already_used, _} ->
        {:error, :already_used}

      {:error, _, _, _} ->
        {:error, :internal}
    end
  end

  # ---------------------------------------------------------------------------
  # Delegated OAuth2/OIDC auth (MSC3861) — no locally-issued token; the
  # client's token is validated by the Authorization Server via introspection,
  # and we just need to map its subject to a local user record.
  # ---------------------------------------------------------------------------

  @doc """
  Resolves an introspected OAuth2 token to `{user_id, device_id}`, creating
  the local user/device on first use if needed.

  Looked up primarily by `oidc_subject` (stable across username changes) —
  a brand-new user is provisioned with `localpart` only if no user has that
  subject yet. Refuses to attach the subject to an existing account that
  isn't already linked to it (or is linked to a *different* subject), so an
  OIDC-side username claim can't silently take over an unrelated local
  (password-based) or other-subject account.

  Returns `{:ok, {user_id, device_id}}` or `{:error, reason}`.
  """
  def authenticate_via_oidc(subject, localpart, device_id, server_name) do
    with {:ok, user_id} <- find_or_create_oidc_user(subject, localpart, server_name) do
      ensure_device(user_id, device_id, nil)
      {:ok, {user_id, device_id}}
    end
  end

  @doc """
  Resolves an application service's own `sender_localpart` user, creating
  the local account on first use — an appservice authenticates with a
  fixed `as_token` (verified by the caller against its registrations, not
  here), not a per-device access token, so there's no separate "login"
  step to have provisioned this user earlier the way a real registration
  would. `device_id` is a stable, caller-chosen id (not per-session): the
  same appservice reusing the same as_token should always resolve to the
  same device row, not accumulate a new one per request.
  """
  def authenticate_via_appservice(localpart, device_id, server_name) do
    user_id = "@#{localpart}:#{server_name}"

    with {:ok, user_id} <- find_or_create_local_user(user_id, localpart) do
      ensure_device(user_id, device_id, nil)
      {:ok, {user_id, device_id}}
    end
  end

  defp find_or_create_local_user(user_id, localpart) do
    case Repo.get(User, user_id) do
      %User{deactivated: true} ->
        {:error, :deactivated}

      %User{} ->
        {:ok, user_id}

      nil ->
        %User{}
        |> User.changeset(%{user_id: user_id, localpart: localpart})
        |> Repo.insert()
        |> case do
          {:ok, user} ->
            Repo.insert(
              UserProfile.changeset(%UserProfile{user_id: user.user_id}, %{displayname: localpart})
            )

            {:ok, user.user_id}

          {:error, _changeset} ->
            {:error, :provisioning_failed}
        end
    end
  end

  defp find_or_create_oidc_user(subject, localpart, server_name) do
    case Repo.get_by(User, oidc_subject: subject) do
      %User{deactivated: true} ->
        {:error, :deactivated}

      %User{user_id: user_id} ->
        {:ok, user_id}

      nil ->
        provision_oidc_user(subject, localpart, server_name)
    end
  end

  defp provision_oidc_user(subject, localpart, server_name) do
    user_id = "@#{localpart}:#{server_name}"

    case Repo.get(User, user_id) do
      nil ->
        %User{}
        |> User.changeset(%{user_id: user_id, localpart: localpart, oidc_subject: subject})
        |> Repo.insert()
        |> case do
          {:ok, user} ->
            Repo.insert(
              UserProfile.changeset(%UserProfile{user_id: user.user_id}, %{displayname: localpart})
            )

            {:ok, user.user_id}

          {:error, _changeset} ->
            {:error, :provisioning_failed}
        end

      %User{oidc_subject: nil} ->
        {:error, :localpart_taken_by_local_account}

      %User{} ->
        {:error, :localpart_taken_by_other_subject}
    end
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

  defp issue_token(user_id, device_id, expires_at_ms \\ nil) do
    raw = generate_raw_token()
    hash = token_hash(raw)

    case Repo.insert(%AccessToken{
           token_hash: hash,
           user_id: user_id,
           device_id: device_id,
           expires_at_ms: expires_at_ms
         }) do
      {:ok, token} -> {:ok, {raw, token}}
      error -> error
    end
  end

  # Issues the token(s) for a fresh login/register: just an access token
  # (never expiring) when `refresh?` is false, exactly as before refresh
  # tokens existed — or an access token with a real expiry plus a paired
  # refresh token when true. Returns `{:ok, %{access_token: ..}}` or
  # `{:ok, %{access_token: .., expires_in_ms: .., refresh_token: ..}}`.
  defp issue_login_tokens(user_id, device_id, refresh?) do
    if refresh? do
      now = System.os_time(:millisecond)
      access_expires_at = now + access_token_lifetime_ms()
      refresh_lifetime_ms = refresh_token_lifetime_ms()
      refresh_expires_at = refresh_lifetime_ms && now + refresh_lifetime_ms
      raw_refresh = generate_raw_token()

      with {:ok, {raw_access, _}} <- issue_token(user_id, device_id, access_expires_at),
           {:ok, _refresh_row} <-
             Repo.insert(
               RefreshToken.changeset(%RefreshToken{}, %{
                 token_hash: token_hash(raw_refresh),
                 user_id: user_id,
                 device_id: device_id,
                 expiry_ts: refresh_expires_at
               })
             ) do
        {:ok,
         %{
           access_token: raw_access,
           expires_in_ms: access_expires_at - now,
           refresh_token: raw_refresh
         }}
      end
    else
      with {:ok, {raw_access, _}} <- issue_token(user_id, device_id) do
        {:ok, %{access_token: raw_access}}
      end
    end
  end

  defp access_token_lifetime_ms,
    do: Application.get_env(:axon_web, :refresh_tokens, [])[:access_token_lifetime_ms] || 300_000

  defp refresh_token_lifetime_ms,
    do: Application.get_env(:axon_web, :refresh_tokens, [])[:refresh_token_lifetime_ms]

  defp generate_raw_token,
    do: :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)

  @doc "Registers `device_id` for `user_id` if it doesn't already exist. Returns `{:ok, device}`."
  def ensure_device(user_id, device_id, display_name) do
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

  @doc "Records that device_id was just used, for GET /devices last_seen_ts/last_seen_ip."
  def touch_device(user_id, device_id, ip) do
    Repo.update_all(
      from(d in Device, where: d.user_id == ^user_id and d.device_id == ^device_id),
      set: [last_seen_ts: System.os_time(:millisecond), last_seen_ip: ip]
    )
  end

  defp token_hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp generate_device_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false) |> String.upcase()
  end
end
