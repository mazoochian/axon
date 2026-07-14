defmodule AxonCore.Schema.Room do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:room_id, :string, autogenerate: false}
  schema "rooms" do
    field(:version, :string, default: "12")
    field(:creator, :string)
    field(:is_public, :boolean, default: false)
    field(:canonical_alias, :string)
    field(:blocked, :boolean, default: false)

    has_many(:memberships, AxonCore.Schema.RoomMembership, foreign_key: :room_id)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:room_id, :version, :creator, :is_public, :canonical_alias])
    |> validate_required([:room_id, :creator])
    |> validate_inclusion(:version, ~w(1 2 3 4 5 6 7 8 9 10 11 12))
  end
end
