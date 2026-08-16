defmodule AxonCore.Repo.Migrations.CreateDeviceListFanoutCursor do
  use Ecto.Migration

  @moduledoc """
  Persists AxonFederation.DeviceListFanout's scan cursor across restarts.

  Previously the cursor lived only in the GenServer's own memory and
  always started at 0 on init — deliberate for a transient supervisor
  restart mid-run (nothing else remembers "was this row already sent" on
  its behalf), but indistinguishable at the Elixir level from a full
  process/container restart, where it means re-scanning the *entire*
  device_list_updates table from the beginning and re-fanning out every
  historical device-list change any local user has ever had, to every
  remote server presently sharing a room with them — including changes
  from long before this boot that every peer already correctly knows
  about. Harmless in isolation (a redundant "something changed, re-query"
  EDU, same idempotent signal a recipient already tolerates out of
  order/duplicated per the module's own moduledoc) but not harmless to a
  strict exact-set assertion of *which* users changed on a given /sync
  response — a redundant re-fan lands as a spurious entry interleaved
  with a real, concurrent change (Complement:
  TestDeviceListsUpdateOverFederation's interrupted_connectivity/
  stopped_server subtests, which restart a homeserver container
  mid-test — the container restart is what triggers a from-scratch
  re-scan).

  A single-row table (id always 1) rather than a bare Application env
  value: must survive the same restart the in-memory cursor doesn't.
  """

  def change do
    create table(:device_list_fanout_cursor, primary_key: false) do
      add(:id, :integer, primary_key: true, default: 1)
      add(:last_id, :bigint, null: false, default: 0)
    end
  end
end
