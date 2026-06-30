defmodule AxonCore.Repo.Migrations.CreateRoomsAndEvents do
  use Ecto.Migration

  def change do
    create table(:rooms, primary_key: false) do
      add :room_id, :text, primary_key: true
      add :version, :text, null: false, default: "12"
      add :creator, :text, null: false
      add :is_public, :boolean, null: false, default: false
      add :canonical_alias, :text

      timestamps(type: :utc_datetime_usec)
    end

    # The primary event store — append-only, never UPDATE or DELETE
    create table(:events) do
      add :event_id, :text, null: false
      add :room_id, references(:rooms, column: :room_id, type: :text), null: false
      add :sender, :text, null: false
      add :type, :text, null: false
      add :state_key, :text
      add :content, :map, null: false
      add :unsigned, :map
      add :origin_server_ts, :bigint, null: false
      add :origin, :text, null: false
      add :auth_event_ids, {:array, :text}, null: false, default: []
      add :prev_event_ids, {:array, :text}, null: false, default: []
      add :depth, :bigint, null: false
      add :signatures, :map, null: false, default: %{}
      add :hashes, :map, null: false, default: %{}
      add :room_version, :text, null: false
      add :rejected, :boolean, null: false, default: false
      add :soft_failed, :boolean, null: false, default: false

      # stream_ordering is assigned at DB insert time — the sync cursor
      add :stream_ordering, :bigserial, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :received_at, updated_at: false)
    end

    create unique_index(:events, [:event_id])
    create unique_index(:events, [:stream_ordering])
    create index(:events, [:room_id, :depth])
    create index(:events, [:room_id, :stream_ordering])

    create index(:events, [:room_id, :type, :state_key],
             where: "state_key IS NOT NULL",
             name: :events_room_state_idx
           )

    create index(:events, [:sender])

    # DAG auth chain edges for fast recursive auth chain lookup
    create table(:event_auth_edges, primary_key: false) do
      add :event_id, :text, null: false
      add :auth_event_id, :text, null: false
    end

    create unique_index(:event_auth_edges, [:event_id, :auth_event_id])
    create index(:event_auth_edges, [:auth_event_id])

    # Materialized current state — kept in sync with events table
    create table(:current_room_state, primary_key: false) do
      add :room_id, references(:rooms, column: :room_id, type: :text), null: false
      add :type, :text, null: false
      add :state_key, :text, null: false
      add :event_id, :text, null: false
    end

    create unique_index(:current_room_state, [:room_id, :type, :state_key],
             name: :current_room_state_pk
           )

    # Periodic snapshots of room state for fast RoomProcess restart
    create table(:room_state_snapshots) do
      add :room_id, references(:rooms, column: :room_id, type: :text), null: false
      add :after_stream_ordering, :bigint, null: false
      # state_map: %{"m.room.member\0@alice:s" => "event_id"}
      add :state_map, :map, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:room_state_snapshots, [:room_id, :after_stream_ordering])

    # Denormalized membership for fast room-member queries
    create table(:room_memberships, primary_key: false) do
      add :room_id, references(:rooms, column: :room_id, type: :text), null: false
      add :user_id, references(:users, column: :user_id, type: :text), null: false
      add :membership, :text, null: false
      add :event_id, :text, null: false
      add :sender, :text, null: false
      add :display_name, :text
      add :avatar_url, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:room_memberships, [:room_id, :user_id])
    create index(:room_memberships, [:user_id, :membership])
    create index(:room_memberships, [:room_id], where: "membership = 'join'",
             name: :room_memberships_joined_idx
           )

    # Room aliases
    create table(:room_aliases, primary_key: false) do
      add :alias, :text, primary_key: true
      add :room_id, references(:rooms, column: :room_id, type: :text), null: false
      add :creator, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:room_aliases, [:room_id])
  end
end
