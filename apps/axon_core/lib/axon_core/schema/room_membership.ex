defmodule AxonCore.Schema.RoomMembership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "room_memberships" do
    field(:room_id, :string)
    field(:user_id, :string)
    field(:membership, :string)
    field(:event_id, :string)
    field(:sender, :string)
    field(:display_name, :string)
    field(:avatar_url, :string)
    field(:forgotten, :boolean, default: false)
    field(:preview_state, :map)

    belongs_to(:room, AxonCore.Schema.Room,
      foreign_key: :room_id,
      references: :room_id,
      define_field: false
    )

    timestamps(type: :utc_datetime_usec)
  end

  @valid_memberships ~w(join leave invite ban knock)

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [
      :room_id,
      :user_id,
      :membership,
      :event_id,
      :sender,
      :display_name,
      :avatar_url
    ])
    |> validate_required([:room_id, :user_id, :membership, :event_id, :sender])
    |> validate_inclusion(:membership, @valid_memberships)
  end
end
