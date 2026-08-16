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

    {:ok, %{user_id: user_id}} =
      UserStore.register(localpart, "Test1234!", server_name: "localhost")

    user_id
  end

  defp content_of(room_id, type, state_key \\ "") do
    case RoomProcess.get_state_event(room_id, type, state_key) do
      nil -> nil
      event -> event["content"]
    end
  end

  # guest_can_join per the createRoom preset table (Client-Server API spec):
  # public_chat is the one preset that does NOT allow guests; both private
  # presets do.
  test "default preset is private_chat: invite join rule, guests can join" do
    creator = new_user("alice")
    assert {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost")

    assert content_of(room_id, "m.room.join_rules")["join_rule"] == "invite"
    assert content_of(room_id, "m.room.guest_access")["guest_access"] == "can_join"
    assert content_of(room_id, "m.room.history_visibility")["history_visibility"] == "shared"
    assert content_of(room_id, "m.room.create")["creator"] == creator
    assert content_of(room_id, "m.room.member", creator)["membership"] == "join"
  end

  test "public_chat preset: public join rule, no explicit guest_access event, invite power 50" do
    creator = new_user("alice")

    assert {:ok, room_id} =
             CreateRoom.execute(creator, preset: "public_chat", server_name: "localhost")

    assert content_of(room_id, "m.room.join_rules")["join_rule"] == "public"
    # Matching Synapse (RoomCreationHandler): guest_can_join is false for
    # public_chat, so no m.room.guest_access state event is sent at all —
    # not even one with content "forbidden". Guest join falls back to the
    # room's implicit default instead of an explicit event.
    assert content_of(room_id, "m.room.guest_access") == nil
    assert content_of(room_id, "m.room.power_levels")["invite"] == 50
  end

  test "explicit initial_state guest_access is honored instead of the auto-generated one" do
    creator = new_user("alice")

    assert {:ok, room_id} =
             CreateRoom.execute(creator,
               server_name: "localhost",
               initial_state: [
                 %{"type" => "m.room.guest_access", "content" => %{"guest_access" => "forbidden"}}
               ]
             )

    # default preset is private_chat (guest_can_join true), which would
    # normally auto-generate a "can_join" guest_access event — but the
    # client's own initial_state already supplied one, so the auto event
    # must be skipped rather than sent as a duplicate/overwrite.
    assert content_of(room_id, "m.room.guest_access")["guest_access"] == "forbidden"
  end

  test "trusted_private_chat preset: invite join rule, invite power 0" do
    creator = new_user("alice")

    assert {:ok, room_id} =
             CreateRoom.execute(creator, preset: "trusted_private_chat", server_name: "localhost")

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
             CreateRoom.execute(creator,
               server_name: "localhost",
               name: "My Room",
               topic: "A topic"
             )

    assert content_of(room_id, "m.room.name")["name"] == "My Room"
    topic_content = content_of(room_id, "m.room.topic")
    assert topic_content["topic"] == "A topic"

    assert get_in(topic_content, ["m.topic", "m.text"]) == [
             %{"body" => "A topic", "mimetype" => "text/plain"}
           ]
  end

  test "room_alias_name registers an alias and sends a canonical_alias event" do
    creator = new_user("alice")
    localpart = "myroomalias#{System.unique_integer([:positive])}"

    assert {:ok, room_id} =
             CreateRoom.execute(creator, server_name: "localhost", room_alias_name: localpart)

    expected_alias = "##{localpart}:localhost"
    assert content_of(room_id, "m.room.canonical_alias")["alias"] == expected_alias

    assert Repo.exists?(
             Ecto.Query.from(a in "room_aliases",
               where: a.alias == ^expected_alias and a.room_id == ^room_id
             )
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

    assert CreateRoom.execute(creator, server_name: "localhost", version: "unsupported") ==
             {:error, :unsupported_room_version}
  end

  describe "check_version_supported/1" do
    test "accepts versions 2 through 12" do
      for v <- ~w(2 3 4 5 6 7 8 9 10 11 12) do
        assert CreateRoom.check_version_supported(v) == :ok
      end
    end

    test "rejects anything else" do
      assert CreateRoom.check_version_supported("1") == {:error, :unsupported_room_version}
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

  describe "room v12" do
    test "the room_id is domainless and hash-derived from the create event" do
      creator = new_user("alice")
      assert {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost", version: "12")

      assert String.starts_with?(room_id, "!")
      refute String.contains?(room_id, ":")
    end

    # The room_id omission is a *federation PDU* rule (EventStore.event_to_pdu/1),
    # not a property of the in-memory/client view — RoomProcess.get_state/1
    # returns the client form, which keeps room_id like every other event.
    # (These used to be the same serialization, so the omission leaked into
    # every client-facing view too; see AxonWeb.RoomV12Test.)
    test "the create event's room_id is omitted from the federation PDU form only" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost", version: "12")

      {:ok, state} = RoomProcess.get_state(room_id)
      create_event = Enum.find(state, &(&1["type"] == "m.room.create"))
      assert create_event["room_id"] == room_id

      {:ok, stored} = AxonCore.EventStore.get_state_event(room_id, "m.room.create", "")
      refute Map.has_key?(AxonCore.EventStore.event_to_pdu(stored), "room_id")
    end

    test "the creator is not listed in power_levels.users (implicit infinite power instead)" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost", version: "12")

      pl = content_of(room_id, "m.room.power_levels")
      refute Map.has_key?(pl["users"] || %{}, creator)
    end

    test "additional_creators (via creation_content) are stored on the create event" do
      creator = new_user("alice")
      bob = new_user("bob")

      {:ok, room_id} =
        CreateRoom.execute(creator,
          server_name: "localhost",
          version: "12",
          creation_content: %{"additional_creators" => [bob]}
        )

      create_content = content_of(room_id, "m.room.create")
      assert create_content["additional_creators"] == [bob]
    end

    test "a malformed additional_creators entry is rejected before the room is created" do
      creator = new_user("alice")

      assert CreateRoom.execute(creator,
               server_name: "localhost",
               version: "12",
               creation_content: %{"additional_creators" => ["not-a-user-id"]}
             ) == {:error, :invalid_additional_creators}
    end

    test "a v12 room's join_rules/history_visibility/etc. still get created normally" do
      creator = new_user("alice")

      {:ok, room_id} =
        CreateRoom.execute(creator,
          server_name: "localhost",
          version: "12",
          preset: "public_chat"
        )

      assert content_of(room_id, "m.room.join_rules")["join_rule"] == "public"
      assert content_of(room_id, "m.room.member", creator)["membership"] == "join"
    end

    test "m.room.tombstone defaults to PL150 (creator-only, MSC4289) instead of PL100" do
      creator = new_user("alice")
      {:ok, room_id} = CreateRoom.execute(creator, server_name: "localhost", version: "12")

      pl = content_of(room_id, "m.room.power_levels")
      assert pl["events"]["m.room.tombstone"] == 150
    end

    test "every other default power level is unchanged from pre-v12" do
      creator = new_user("alice")
      {:ok, v11_room} = CreateRoom.execute(creator, server_name: "localhost", version: "11")
      {:ok, v12_room} = CreateRoom.execute(creator, server_name: "localhost", version: "12")

      v11_pl = content_of(v11_room, "m.room.power_levels") |> Map.delete("users")
      v12_pl = content_of(v12_room, "m.room.power_levels") |> Map.delete("users")

      v11_events = Map.delete(v11_pl["events"], "m.room.tombstone")
      v12_events = Map.delete(v12_pl["events"], "m.room.tombstone")

      assert v11_events == v12_events
      assert Map.delete(v11_pl, "events") == Map.delete(v12_pl, "events")
    end

    test "trusted_private_chat + invite auto-adds invitees to additional_creators" do
      creator = new_user("alice")
      bob = new_user("bob")

      {:ok, room_id} =
        CreateRoom.execute(creator,
          server_name: "localhost",
          version: "12",
          preset: "trusted_private_chat",
          is_direct: true,
          invite: [bob]
        )

      create_content = content_of(room_id, "m.room.create")
      assert create_content["additional_creators"] == [bob]
    end

    test "trusted_private_chat auto-add unions with, rather than replaces, explicit additional_creators" do
      creator = new_user("alice")
      bob = new_user("bob")
      charlie = new_user("charlie")

      {:ok, room_id} =
        CreateRoom.execute(creator,
          server_name: "localhost",
          version: "12",
          preset: "trusted_private_chat",
          is_direct: true,
          invite: [bob],
          creation_content: %{"additional_creators" => [charlie]}
        )

      create_content = content_of(room_id, "m.room.create")
      assert Enum.sort(create_content["additional_creators"]) == Enum.sort([bob, charlie])
    end

    test "is_direct is echoed onto each initial invite's own m.room.member content" do
      creator = new_user("alice")
      bob = new_user("bob")

      assert {:ok, room_id} =
               CreateRoom.execute(creator, server_name: "localhost", is_direct: true, invite: [bob])

      assert content_of(room_id, "m.room.member", bob) == %{
               "membership" => "invite",
               "is_direct" => true
             }
    end

    test "without is_direct, an initial invite's content is just the membership" do
      creator = new_user("alice")
      bob = new_user("bob")

      assert {:ok, room_id} =
               CreateRoom.execute(creator, server_name: "localhost", invite: [bob])

      assert content_of(room_id, "m.room.member", bob) == %{"membership" => "invite"}
    end

    test "trusted_private_chat with no invite doesn't add an empty additional_creators key" do
      creator = new_user("alice")

      {:ok, room_id} =
        CreateRoom.execute(creator,
          server_name: "localhost",
          version: "12",
          preset: "trusted_private_chat"
        )

      create_content = content_of(room_id, "m.room.create")
      refute Map.has_key?(create_content, "additional_creators")
    end

    test "non-v12 trusted_private_chat does not touch additional_creators (v12-only mechanism)" do
      creator = new_user("alice")
      bob = new_user("bob")

      {:ok, room_id} =
        CreateRoom.execute(creator,
          server_name: "localhost",
          version: "11",
          preset: "trusted_private_chat",
          invite: [bob]
        )

      create_content = content_of(room_id, "m.room.create")
      refute Map.has_key?(create_content, "additional_creators")
    end

    test "an additional_creators domain with invalid characters is rejected" do
      creator = new_user("alice")

      assert CreateRoom.execute(creator,
               server_name: "localhost",
               version: "12",
               creation_content: %{"additional_creators" => ["@invalid:dom$ain$.com"]}
             ) == {:error, :invalid_additional_creators}
    end
  end

  describe "power_level_content_override" do
    test "is merged on top of the default power_levels content" do
      creator = new_user("alice")
      bob = new_user("bob")

      {:ok, room_id} =
        CreateRoom.execute(creator,
          server_name: "localhost",
          version: "12",
          invite: [bob],
          power_level_content_override: %{"users" => %{bob => 100}}
        )

      pl = content_of(room_id, "m.room.power_levels")
      assert pl["users"] == %{bob => 100}
    end

    test "unspecified fields keep the generated defaults (shallow top-level merge)" do
      creator = new_user("alice")

      {:ok, room_id} =
        CreateRoom.execute(creator,
          server_name: "localhost",
          version: "11",
          power_level_content_override: %{"invite" => 25}
        )

      pl = content_of(room_id, "m.room.power_levels")
      assert pl["invite"] == 25
      # untouched defaults survive
      assert pl["ban"] == 50
      assert pl["users"][creator] == 100
    end

    test "v12: an override naming the room creator in users is rejected rather than silently applied" do
      creator = new_user("alice")

      assert CreateRoom.execute(creator,
               server_name: "localhost",
               version: "12",
               power_level_content_override: %{"users" => %{creator => 100}}
             ) == {:error, :power_levels_may_not_list_creators}
    end

    test "v12: an override naming an additional_creator in users is also rejected" do
      creator = new_user("alice")
      bob = new_user("bob")

      assert CreateRoom.execute(creator,
               server_name: "localhost",
               version: "12",
               creation_content: %{"additional_creators" => [bob]},
               power_level_content_override: %{"users" => %{bob => 100}}
             ) == {:error, :power_levels_may_not_list_creators}
    end

    test "pre-v12: an override that supplies users without the creator is rejected (would lock them out)" do
      creator = new_user("alice")
      bob = new_user("bob")

      assert CreateRoom.execute(creator,
               server_name: "localhost",
               version: "11",
               power_level_content_override: %{"users" => %{bob => 100}}
             ) == {:error, :power_level_content_override_excludes_creator}
    end

    test "pre-v12: an override that supplies users including the creator is accepted" do
      creator = new_user("alice")
      bob = new_user("bob")

      assert {:ok, room_id} =
               CreateRoom.execute(creator,
                 server_name: "localhost",
                 version: "11",
                 power_level_content_override: %{"users" => %{creator => 100, bob => 50}}
               )

      pl = content_of(room_id, "m.room.power_levels")
      assert pl["users"] == %{creator => 100, bob => 50}
    end

    test "a non-map override is rejected before anything is created" do
      creator = new_user("alice")

      assert CreateRoom.execute(creator,
               server_name: "localhost",
               power_level_content_override: "not-a-map"
             ) == {:error, :invalid_power_level_content_override}
    end
  end
end
