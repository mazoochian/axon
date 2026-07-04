defmodule AxonCore.Repo.Migrations.CreateOidcDeviceBindings do
  use Ecto.Migration

  # Maps a delegated-OIDC access token (identified by its hash, never the raw
  # token) to a stable device_id, for ASes/clients whose introspection
  # response doesn't carry a urn:matrix:client:device:<id> scope. Without
  # this, a fresh random device_id would otherwise be minted on every
  # request, making it impossible for a client to ever establish a coherent
  # device/cross-signing identity.
  def change do
    create table(:oidc_device_bindings) do
      add :token_hash, :text, null: false
      add :device_id, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:oidc_device_bindings, [:token_hash])
  end
end
