defmodule AxonCore.Repo.Migrations.CreateAppserviceOutboundTransactions do
  use Ecto.Migration

  def change do
    # Durable outbound Application Service delivery queue — mirrors
    # `federation_outbound_transactions` (AxonFederation.OutboundQueue,
    # Phase 9): a homeserver->AS event push (`PUT /_matrix/app/v1/transactions/:txn_id`)
    # is persisted here before the first delivery attempt and retried with
    # backoff on failure, instead of the previous Phase-4 behavior where a
    # failed push just logged a warning and the events were dropped —
    # meaning a bridge being briefly unreachable silently lost whatever
    # happened in its namespace during that window.
    create table(:appservice_outbound_transactions) do
      # The application service's `id` (from its registration), not a URL —
      # resolved to the current registration (and therefore current url/
      # hs_token) at delivery time, so an admin updating a registration
      # file takes effect on the next retry without orphaning in-flight rows.
      add :as_id, :text, null: false
      add :payload, :map, null: false
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec, null: false
      add :last_error, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:appservice_outbound_transactions, [:next_attempt_at])
    create index(:appservice_outbound_transactions, [:as_id])
  end
end
