defmodule AxonCore.ScopeClientTransactionsMigrationTest do
  use AxonCore.DataCase, async: false

  @migration_path Path.expand(
                    "../../priv/repo/migrations/20260818000001_scope_client_transactions.exs",
                    __DIR__
                  )
  Code.require_file(@migration_path)

  test "down deduplicates exact timestamp and event-id ties deterministically" do
    Repo.query!(
      "CREATE TEMP TABLE client_txns_tie (LIKE client_txns INCLUDING DEFAULTS) ON COMMIT DROP"
    )

    Repo.query!("ALTER TABLE client_txns_tie DROP CONSTRAINT IF EXISTS client_txns_tie_pkey")

    timestamp = ~U[2026-08-18 00:00:00.000000Z]

    base = %{
      user_id: "@tie:localhost",
      device_id: "D",
      txn_id: "T",
      event_id: "$same",
      inserted_at: timestamp
    }

    Repo.insert_all("client_txns_tie", [
      Map.put(base, :request_scope, "a"),
      Map.put(base, :request_scope, "b")
    ])

    sql =
      AxonCore.Repo.Migrations.ScopeClientTransactions.down_dedupe_sql()
      |> String.replace("client_txns", "client_txns_tie")

    Repo.query!(sql)
    assert Repo.aggregate("client_txns_tie", :count) == 1
    assert Repo.one(from(t in "client_txns_tie", select: t.request_scope)) == "a"
  end
end
