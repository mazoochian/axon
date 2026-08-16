defmodule AxonCore.Schema.AccessToken do
  use Ecto.Schema
  import Ecto.Changeset

  schema "access_tokens" do
    field(:token_hash, :string)
    field(:user_id, :string)
    field(:device_id, :string)
    field(:valid, :boolean, default: true)
    field(:last_validated, :utc_datetime_usec)
    # Millisecond epoch timestamp; nil means "never expires" — the default
    # for every access token minted without `refresh_token: true` at
    # login/register, exactly as before this field existed.
    field(:expires_at_ms, :integer)

    belongs_to(:user, AxonCore.Schema.User,
      foreign_key: :user_id,
      references: :user_id,
      define_field: false
    )

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token_hash, :user_id, :device_id, :valid, :expires_at_ms])
    |> validate_required([:token_hash, :user_id, :device_id])
    |> unique_constraint(:token_hash)
  end
end
