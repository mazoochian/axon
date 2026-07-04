defmodule AxonCore.Repo.Migrations.AddMessageSearchIndex do
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX events_body_fts_idx ON events
    USING GIN (to_tsvector('english', content->>'body'))
    WHERE type = 'm.room.message'
    """)
  end

  def down do
    execute("DROP INDEX events_body_fts_idx")
  end
end
