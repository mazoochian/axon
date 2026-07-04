defmodule AxonCore.Repo.Migrations.DropRoomMembershipsUserFk do
  use Ecto.Migration

  # room_memberships.user_id must be able to reference a user on ANY server,
  # not just local accounts — a federated room's membership list legitimately
  # contains remote users who have (and should never have) a row in the local
  # `users` table. The FK added in 20260630000002 makes that structurally
  # impossible: inserting a remote member's m.room.member event fails with a
  # foreign_key_violation and rolls back the whole insert_event transaction
  # (the event itself never gets persisted either). This was never caught
  # because the only existing federation test used a local user standing in
  # for a "remote" sender.
  #
  # Bring user_id in line with how every other user-reference column in this
  # schema already works (events.sender, rooms.creator, etc.): plain text,
  # no FK, since the referenced user may not be local.
  def change do
    drop constraint(:room_memberships, "room_memberships_user_id_fkey")
  end
end
