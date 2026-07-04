defmodule AxonRoom.RoomUpgradeTest do
  @moduledoc """
  Direct (non-HTTP) tests for `AxonRoom.RoomUpgrade` — guard clauses and the
  tombstone+recreate flow itself. HTTP-level integration (the `/upgrade`
  endpoint, permission responses) lives in `apps/axon_web/test/room_upgrade_test.exs`.
  """

  use AxonRoom.DataCase, async: false

  alias AxonCore.UserStore
  alias AxonRoom.{CreateRoom, RoomProcess, RoomUpgrade}

  defp new_user(prefix) do
    localpart = "#{prefix}_#{System.unique_integer([:positive])}"
    {:ok, %{user_id: user_id}} = UserStore.register(localpart, "Test1234!", server_name: "localhost")
    user_id
  end

  defp content_of(room_id, type, state_key \\ "") do
    case RoomProcess.get_state_event(room_id, type, state_key) do
      nil -> nil
      event -> event["content"]
    end
  end

  describe "ensure_joined/2" do
    test "ok when the user is joined" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")
      assert RoomUpgrade.ensure_joined(room_id, creator) == :ok
    end

    test "not_joined when the user has no membership" do
      creator = new_user("alice")
      bob = new_user("bob")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")
      assert RoomUpgrade.ensure_joined(room_id, bob) == {:error, :not_joined}
    end
  end

  describe "ensure_can_tombstone/2" do
    test "ok for the room creator (power 100)" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")
      assert RoomUpgrade.ensure_can_tombstone(room_id, creator) == :ok
    end

    test "insufficient_power_level for a default-power member" do
      creator = new_user("alice")
      bob = new_user("bob")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost", preset: "public_chat")
      {:ok, _} = RoomProcess.send_event(room_id, bob, "m.room.member", %{"membership" => "join"}, state_key: bob)

      assert RoomUpgrade.ensure_can_tombstone(room_id, bob) == {:error, :insufficient_power_level}
    end
  end

  describe "execute/4" do
    test "tombstones the old room and creates a new one with copied state" do
      creator = new_user("alice")

      {:ok, old_room_id} =
        CreateRoom.execute(creator, server_name: "localhost", name: "Old Name", preset: "public_chat")

      assert {:ok, new_room_id} = RoomUpgrade.execute(old_room_id, creator, "9", "localhost")
      refute new_room_id == old_room_id

      tombstone = content_of(old_room_id, "m.room.tombstone")
      assert tombstone["replacement_room"] == new_room_id

      create_content = content_of(new_room_id, "m.room.create")
      assert create_content["room_version"] == "9"
      assert create_content["predecessor"]["room_id"] == old_room_id
      assert create_content["predecessor"]["event_id"]

      # Copied state survives into the new room.
      assert content_of(new_room_id, "m.room.join_rules")["join_rule"] ==
               content_of(old_room_id, "m.room.join_rules")["join_rule"]
    end

    test "rejects an unsupported target version without touching the old room" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")

      assert RoomUpgrade.execute(room_id, creator, "unsupported", "localhost") ==
               {:error, :unsupported_room_version}

      refute content_of(room_id, "m.room.tombstone")
    end
  end
end
