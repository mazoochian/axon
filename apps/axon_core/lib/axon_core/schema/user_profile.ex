defmodule AxonCore.Schema.UserProfile do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:user_id, :string, autogenerate: false}
  schema "user_profiles" do
    field(:displayname, :string)
    field(:avatar_url, :string)

    belongs_to(:user, AxonCore.Schema.User,
      foreign_key: :user_id,
      references: :user_id,
      define_field: false
    )

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:user_id, :displayname, :avatar_url])
    |> validate_required([:user_id])
    |> validate_length(:displayname, max: 255)
  end
end
