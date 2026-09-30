defmodule AxonRoom.EventBuilderTest do
  use ExUnit.Case, async: true

  alias AxonRoom.EventBuilder

  @authoriser "@auth:localhost"
  @joiner "@joiner:remote.test"

  defp ctx do
    current_state =
      Map.new([
        {{"m.room.create", ""}, %{"event_id" => "$create"}},
        {{"m.room.join_rules", ""}, %{"event_id" => "$join_rules"}},
        {{"m.room.power_levels", ""}, %{"event_id" => "$pl"}},
        {{"m.room.member", @authoriser}, %{"event_id" => "$authoriser_join"}}
      ])

    %{
      room_id: "!room:localhost",
      room_version: "10",
      current_state: current_state,
      last_event_id: "$join_rules",
      depth: 3
    }
  end

  defp build_join(content),
    do: EventBuilder.build(@joiner, "m.room.member", content, ctx(), state_key: @joiner)

  test "a restricted join cites the authorising user's membership in auth_events" do
    event =
      build_join(%{"membership" => "join", "join_authorised_via_users_server" => @authoriser})

    assert "$authoriser_join" in event["auth_events"]
  end

  test "a plain join does not cite unrelated memberships" do
    refute "$authoriser_join" in build_join(%{"membership" => "join"})["auth_events"]
  end
end
