defmodule AxonCore.Schema.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:user_id, :string, autogenerate: false}
  schema "users" do
    field :localpart, :string
    field :password_hash, :string
    field :oidc_subject, :string
    field :deactivated, :boolean, default: false
    field :admin, :boolean, default: false

    has_one :profile, AxonCore.Schema.UserProfile, foreign_key: :user_id
    has_many :devices, AxonCore.Schema.Device, foreign_key: :user_id
    has_many :access_tokens, AxonCore.Schema.AccessToken, foreign_key: :user_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:user_id, :localpart, :password_hash, :oidc_subject, :deactivated, :admin])
    |> validate_required([:user_id, :localpart])
    |> validate_format(:user_id, ~r/^@[^:]+:.+$/, message: "must be in @localpart:server format")
    |> unique_constraint(:localpart)
    |> unique_constraint(:oidc_subject)
  end
end
