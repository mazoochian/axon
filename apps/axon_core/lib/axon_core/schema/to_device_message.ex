defmodule AxonCore.Schema.ToDeviceMessage do
  use Ecto.Schema
  import Ecto.Changeset

  schema "to_device_messages" do
    field :sender, :string
    field :target_user_id, :string
    field :target_device_id, :string
    field :type, :string
    field :content, :map
    field :stream_ordering, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(msg, attrs) do
    msg
    |> cast(attrs, [:sender, :target_user_id, :target_device_id, :type, :content])
    |> validate_required([:sender, :target_user_id, :target_device_id, :type, :content])
  end
end
