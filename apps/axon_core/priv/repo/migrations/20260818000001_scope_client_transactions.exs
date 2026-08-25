defmodule AxonCore.Repo.Migrations.ScopeClientTransactions do
  use Ecto.Migration

  def up do
    alter table(:client_txns) do
      add(:request_scope, :text)
    end

    # Historical rows do not record which endpoint created a redaction. A
    # dedicated /redact row therefore cannot recover its target-specific scope;
    # it is backfilled with the canonical normal-send scope like every other
    # event. New dedicated redacts use the tagged target-aware encoder.
    execute("""
    UPDATE client_txns AS txn
    SET request_scope = octet_length('send')::text || ':send' ||
                        octet_length(event.room_id)::text || ':' || event.room_id ||
                        octet_length(event.type)::text || ':' || event.type
    FROM events AS event
    WHERE event.event_id = txn.event_id
    """)

    execute("""
    UPDATE client_txns
    SET request_scope = 'legacy:' || event_id
    WHERE request_scope IS NULL
    """)

    alter table(:client_txns) do
      modify(:request_scope, :text, null: false)
    end

    drop(unique_index(:client_txns, [:user_id, :device_id, :txn_id]))

    create(
      unique_index(
        :client_txns,
        [:user_id, :device_id, :txn_id, :request_scope],
        name: :client_txns_request_unique_index
      )
    )
  end

  def down do
    drop(
      unique_index(:client_txns, [:user_id, :device_id, :txn_id, :request_scope],
        name: :client_txns_request_unique_index
      )
    )

    # A scoped database can contain several rows for the old three-column key.
    # Keep one deterministic mapping so the old uniqueness invariant is restored.
    execute(down_dedupe_sql())

    create(unique_index(:client_txns, [:user_id, :device_id, :txn_id]))

    alter table(:client_txns) do
      remove(:request_scope)
    end
  end

  def down_dedupe_sql do
    """
    DELETE FROM client_txns AS duplicate
    USING client_txns AS keeper
    WHERE duplicate.user_id = keeper.user_id
      AND duplicate.device_id = keeper.device_id
      AND duplicate.txn_id = keeper.txn_id
      AND (duplicate.inserted_at, duplicate.event_id, duplicate.request_scope) >
          (keeper.inserted_at, keeper.event_id, keeper.request_scope)
    """
  end
end
