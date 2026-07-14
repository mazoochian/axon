defmodule AxonCore.Repo.Migrations.CreateEphemeralUpdates do
  use Ecto.Migration

  def change do
    # Records that room_id has a new typing or receipt change, for /sync's
    # per-room ephemeral section. Mirrors device_list_updates: a plain
    # "something changed here" log, not the ephemeral data itself (typing
    # lives in ETS via AxonSync.Typing; receipts already live in the
    # `receipts` table) — /sync recomputes the room's current ephemeral
    # state fresh on every response, this table only decides whether a room
    # with no *timeline* changes still needs to be included at all.
    create table(:ephemeral_updates) do
      add :room_id, :text, null: false
    end

    create index(:ephemeral_updates, [:room_id])
  end
end
