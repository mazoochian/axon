defmodule AxonCore.Schema.OidcDeviceBinding do
  use Ecto.Schema
  import Ecto.Changeset

  schema "oidc_device_bindings" do
    field(:token_hash, :string)
    field(:device_id, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:token_hash, :device_id])
    |> validate_required([:token_hash, :device_id])
    |> unique_constraint(:token_hash)
  end
end
