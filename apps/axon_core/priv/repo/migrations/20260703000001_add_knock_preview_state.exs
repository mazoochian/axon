defmodule AxonCore.Repo.Migrations.AddKnockPreviewState do
  use Ecto.Migration

  def change do
    alter table(:room_memberships) do
      # Stripped room state (name/avatar/topic/join_rules/...), stored for
      # knocks so /sync can render a room preview even when we don't have
      # the room's full state locally (a knock on a remote room we've never
      # joined). Shape: %{"events" => [stripped_event, ...]}.
      add :preview_state, :map
    end
  end
end
