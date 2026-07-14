defmodule AxonCore.Repo.Migrations.CreateFederationOutboundTransactions do
  use Ecto.Migration

  def change do
    # Durable outbound federation delivery queue. A PDU/EDU transaction is
    # persisted here before the first delivery attempt and retried with
    # backoff on failure (see AxonFederation.OutboundQueue), instead of the
    # previous fire-and-forget behavior where a failed HTTP request just
    # logged a warning and the transaction was lost — meaning a remote
    # server being briefly unreachable silently dropped room events and
    # to-device/EDU traffic sent to it during that window.
    create table(:federation_outbound_transactions) do
      add :destination, :text, null: false
      add :payload, :map, null: false
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec, null: false
      add :last_error, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:federation_outbound_transactions, [:next_attempt_at])
    create index(:federation_outbound_transactions, [:destination])
  end
end
