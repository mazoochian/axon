defmodule AxonCore.Repo.Migrations.CreateReports do
  use Ecto.Migration

  def change do
    create table(:reports) do
      add :room_id, references(:rooms, column: :room_id, type: :text), null: false
      # NULL for a whole-room report; set for POST .../report/:eventId
      add :event_id, :text
      add :reporter_id, :text, null: false
      add :reason, :text
      # Deprecated per-spec 0..100 "how bad is it" score, still sent by some clients.
      add :score, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:reports, [:room_id])
    create index(:reports, [:event_id])
  end
end
