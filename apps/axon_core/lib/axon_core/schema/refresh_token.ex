defmodule AxonCore.Schema.RefreshToken do
  @moduledoc """
  A refresh token (stable Matrix spec, formerly MSC2918), tied to a
  user_id + device_id like `AccessToken`. Single-use: once exchanged via
  `AxonCore.UserStore.refresh/1` it is rotated forward by pointing
  `next_token_id` at its successor rather than being deleted, so a replay
  of an already-used token can be told apart from one that never existed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "refresh_tokens" do
    field(:token_hash, :string)
    field(:user_id, :string)
    field(:device_id, :string)
    # References another refresh_tokens row's id once this token has been
    # exchanged for a new pair — presence (not nil) is what makes reuse of
    # this token rejected as already-used rather than accepted again.
    field(:next_token_id, :integer)
    # Millisecond epoch timestamps, both nullable — nil means "never
    # expires", matching Synapse's own `refresh_token_lifetime: None`
    # default. `ultimate_session_expiry_ts` bounds the whole refresh chain
    # (carried forward unchanged across rotations) but nothing in this
    # codebase sets it yet; it exists so a future session-lifetime cap can
    # be added without another migration.
    field(:expiry_ts, :integer)
    field(:ultimate_session_expiry_ts, :integer)

    belongs_to(:user, AxonCore.Schema.User,
      foreign_key: :user_id,
      references: :user_id,
      define_field: false
    )

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token_hash,
      :user_id,
      :device_id,
      :next_token_id,
      :expiry_ts,
      :ultimate_session_expiry_ts
    ])
    |> validate_required([:token_hash, :user_id, :device_id])
    |> unique_constraint(:token_hash)
  end
end
