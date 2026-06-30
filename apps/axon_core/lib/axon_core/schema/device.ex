defmodule AxonCore.Schema.Device do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "devices" do
    field :device_id, :string
    field :user_id, :string
    field :display_name, :string
    field :last_seen_ts, :integer
    field :last_seen_ip, :string

    belongs_to :user, AxonCore.Schema.User, foreign_key: :user_id, references: :user_id, define_field: false

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:device_id, :user_id, :display_name, :last_seen_ts])
    |> validate_required([:device_id, :user_id])
  end
end
