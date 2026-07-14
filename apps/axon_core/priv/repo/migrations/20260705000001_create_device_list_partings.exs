defmodule AxonCore.Repo.Migrations.CreateDeviceListPartings do
  use Ecto.Migration

  def change do
    # Records that `subject_user_id` no longer shares any room with
    # `observer_user_id` (as of the leave/kick/ban that caused it), so
    # /sync device_lists.left and /keys/changes `left` can report it without
    # relying on current room membership (which, by definition, no longer
    # includes the parted pair).
    create table(:device_list_partings) do
      add :observer_user_id, :text, null: false
      add :subject_user_id, :text, null: false
    end

    create index(:device_list_partings, [:observer_user_id])
  end
end
