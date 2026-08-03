defmodule AxonCore.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  @moduledoc """
  A durable ledger of "this event generated a notify push-rule action for
  this user" rows, written by `AxonPush.Dispatcher` alongside (but
  independent of) actual HTTP push delivery. Backs
  `GET /_matrix/client/v3/notifications`, which needs real pagination over
  past notifications (actions taken, event content, timestamp) — something
  that can't be reconstructed by re-running *current* push rules over old
  events the way the live `unread_notifications`/`notification_count`
  badge (`AxonWeb.SyncHelpers.unread_counts/2`) is: a push rule the user
  changes later must not rewrite what was already decided about a past
  event.
  """

  def change do
    create table(:notifications) do
      add(:user_id, :text, null: false)
      add(:room_id, :text, null: false)
      add(:event_id, :text, null: false)
      add(:sender, :text, null: false)
      # The push-rule actions that matched (includes the "notify" action
      # itself and any set_tweak entries, e.g. highlight/sound) — stored
      # verbatim so /notifications can echo back exactly what was decided.
      add(:actions, {:array, :map}, null: false)
      add(:highlight, :boolean, null: false, default: false)
      # Denormalized from events.stream_ordering at write time: lets
      # "read" (per GET /notifications) be computed on the fly by
      # comparing against the user's *current* read-receipt position,
      # rather than maintaining a stored read flag that would need
      # updating every time a receipt moves (forward OR backward).
      add(:stream_ordering, :bigint, null: false)
      add(:ts, :bigint, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Pagination cursor for GET /notifications (newest-first by id).
    create(index(:notifications, [:user_id, :id]))
    # Idempotency: a duplicate dispatch of the same event to the same user
    # (there isn't one in the current call graph, but fire-and-forget code
    # is exactly the kind of thing that grows one) must not double-count.
    create(unique_index(:notifications, [:user_id, :event_id]))
  end
end
