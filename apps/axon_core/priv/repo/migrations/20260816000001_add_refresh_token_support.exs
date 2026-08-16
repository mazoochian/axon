defmodule AxonCore.Repo.Migrations.AddRefreshTokenSupport do
  use Ecto.Migration

  def change do
    # Real expiry for access tokens (stable Matrix spec, formerly MSC2918).
    # NULL keeps today's behavior — an access token minted without
    # `refresh_token: true` at login/register never expires, exactly as
    # before this migration — matching Synapse's own default of
    # `nonrefreshable_access_token_lifetime: None`.
    alter table(:access_tokens) do
      add(:expires_at_ms, :bigint)
    end

    # The `refresh_tokens` table itself was already created by
    # 20260630000001_create_users_and_auth.exs (token_hash, user_id,
    # device_id, next_token_id, expiry_ts, ultimate_session_expiry_ts) but
    # has gone unused until now — no application code referenced it. Add
    # the lookup index its actual usage (rotation on logout/logout_all,
    # scoped per user+device) needs.
    create(index(:refresh_tokens, [:user_id, :device_id]))
  end
end
