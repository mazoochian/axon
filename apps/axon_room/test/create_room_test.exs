defmodule AxonRoom.CreateRoomTest do
  @moduledoc """
  Tests `AxonRoom.CreateRoom.execute/2` end to end against real `RoomProcess`
  GenServers and Postgres (via `AxonRoom.DataCase`), covering presets, custom
  initial state, aliasing, invites, and version validation.
  """

  use AxonRoom.DataCase, async: false

  alias AxonCore.{Repo, UserStore}
  alias AxonRoom.{CreateRoom, RoomProcess}

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

  test "default preset is private_chat: invite join rule, forbidden guest access" do
    creator = new_user("alice")
    assert {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")

    assert content_of(room_id, "m.room.join_rules")["join_rule"] == "invite"
    assert content_of(room_id, "m.room.guest_access")["guest_access"] == "forbidden"
    assert content_of(room_id, "m.room.history_visibility")["history_visibility"] == "shared"
    assert content_of(room_id, "m.room.create")["creator"] == creator
    assert content_of(room_id, "m.room.member", creator)["membership"] == "join"
  end

  test "public_chat preset: public join rule, can_join guest access, invite power 50" do
    creator = new_user("alice")
    assert {:ok, room_id} = CreateRoom.execute(creator, preset: "public_chat", server_name: "localhost")

    assert content_of(room_id, "m.room.join_rules")["join_rule"] == "public"
    assert content_of(room_id, "m.room.guest_access")["guest_access"] == "can_join"
    assert content_of(room_id, "m.room.power_levels")["invite"] == 50
  end

  test "trusted_private_chat preset: invite join rule, invite power 0" do
    creator = new_user("alice")
    assert {:ok, room_id} = CreateRoom.execute(creator, preset: "trusted_private_chat", server_name: "localhost")

    assert content_of(room_id, "m.room.join_rules")["join_rule"] == "invite"
    assert content_of(room_id, "m.room.power_levels")["invite"] == 0
  end

  test "creator always gets power level 100" do
    creator = new_user("alice")
    assert {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")
    assert content_of(room_id, "m.room.power_levels")["users"][creator] == 100
  end

  test "custom initial_state events are applied" do
    creator = new_user("alice")

    assert {:ok, room_id} =
             CreateRoom.execute(creator,
               server_name: "localhost",
               initial_state: [%{"type" => "m.room.custom_thing", "content" => %{"foo" => "bar"}}]
             )

    assert content_of(room_id, "m.room.custom_thing")["foo"] == "bar"
  end

  test "name and topic are set when provided, topic includes MSC3765 rich representation" do
    creator = new_user("alice")

    assert {:ok, room_id} =
             CreateRoom.execute(creator, server_name: "localhost", name: "My Room", topic: "A topic")

    assert content_of(room_id, "m.room.name")["name"] == "My Room"
    topic_content = content_of(room_id, "m.room.topic")
    assert topic_content["topic"] == "A topic"
    assert get_in(topic_content, ["m.topic", "m.text"]) == [%{"body" => "A topic", "mimetype" => "text/plain"}]
  end

  test "room_alias_name registers an alias and sends a canonical_alias event" do
    creator = new_user("alice")
    localpart = "myroomalias#{System.unique_integer([:positive])}"

    assert {:ok, room_id} =
             CreateRoom.execute(creator, server_name: "localhost", room_alias_name: localpart)

    expected_alias = "##{localpart}:localhost"
    assert content_of(room_id, "m.room.canonical_alias")["alias"] == expected_alias

    assert Repo.exists?(
             Ecto.Query.from(a in "room_aliases", where: a.alias == ^expected_alias and a.room_id == ^room_id)
           )
  end

  test "invited users get an invite membership event" do
    creator = new_user("alice")
    bob = new_user("bob")

    assert {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost", invite: [bob])
    assert content_of(room_id, "m.room.member", bob)["membership"] == "invite"
  end

  test "creation_content is merged but cannot override room_version" do
    creator = new_user("alice")

    assert {:ok, room_id} =
             CreateRoom.execute(creator,
               server_name: "localhost",
               version: "10",
               creation_content: %{"room_version" => "99", "custom_field" => "kept"}
             )

    create_content = content_of(room_id, "m.room.create")
    assert create_content["room_version"] == "10"
    assert create_content["custom_field"] == "kept"
  end

  test "an unsupported room version is rejected before anything is created" do
    creator = new_user("alice")
    assert CreateRoom.execute(creator, server_name: "localhost", version: "unsupported") == {:error, :unsupported_room_version}
  end

  describe "check_version_supported/1" do
    test "accepts versions 2 through 11" do
      for v <- ~w(2 3 4 5 6 7 8 9 10 11) do
        assert CreateRoom.check_version_supported(v) == :ok
      end
    end

    test "rejects anything else" do
      assert CreateRoom.check_version_supported("12") == {:error, :unsupported_room_version}
      assert CreateRoom.check_version_supported("garbage") == {:error, :unsupported_room_version}
    end
  end

  describe "generate_room_id/1" do
    test "produces a well-formed, unique room id for the given server" do
      id1 = CreateRoom.generate_room_id("localhost")
      id2 = CreateRoom.generate_room_id("localhost")

      assert String.starts_with?(id1, "!")
      assert String.ends_with?(id1, ":localhost")
      refute id1 == id2
    end
  end
end
