defmodule AxonWeb.E2E.SearchDirectoryFlowTest do
  @moduledoc """
  End-to-end discovery flow chaining pieces that are each unit-tested
  individually (alias CRUD, publicRooms listing, user directory, message
  search) but never exercised together: publish a room under an alias ->
  a stranger discovers it via publicRooms and the user directory -> joins
  by alias (not room_id) -> posts a message -> the joiner can search it,
  but a second stranger who never joined can't, and the room stops
  appearing in the directory once made private again.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  defp encode_alias(room_alias), do: room_alias |> URI.encode() |> String.replace("#", "%23")

  test "publish -> discover via directory/user_directory -> join by alias -> search -> unpublish" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    dana = register("dana_#{System.unique_integer([:positive])}")
    stranger = register("stranger_#{System.unique_integer([:positive])}")

    unique = "zorkspace#{System.unique_integer([:positive])}"
    room_id =
      create_room(alice.token, %{
        "preset" => "public_chat",
        "name" => unique,
        "visibility" => "public"
      })

    room_alias = "##{unique}:localhost"
    alias_conn = authed(alice.token) |> jpu("/_matrix/client/v3/directory/room/#{encode_alias(room_alias)}", %{"room_id" => room_id})
    assert alias_conn.status == 200

    # --- dana discovers the room via publicRooms, by name ---
    directory_conn =
      authed(dana.token)
      |> jp("/_matrix/client/v3/publicRooms", %{"filter" => %{"generic_search_term" => unique}})

    assert Enum.any?(decode(directory_conn)["chunk"], &(&1["room_id"] == room_id))

    # --- dana also discovers alice herself via the user directory ---
    ud_conn = authed(dana.token) |> jp("/_matrix/client/v3/user_directory/search", %{"search_term" => "alice_"})
    assert Enum.any?(decode(ud_conn)["results"], &(&1["user_id"] == alice.user_id))

    # --- dana joins by ALIAS, not room_id ---
    join_conn = authed(dana.token) |> jp("/_matrix/client/v3/join/#{encode_alias(room_alias)}", %{})
    assert join_conn.status == 200
    assert decode(join_conn)["room_id"] == room_id

    unique_phrase = "findme#{System.unique_integer([:positive])}"
    message_event_id = send_event(alice.token, room_id, "m.room.message", %{"msgtype" => "m.text", "body" => "#{unique_phrase} secrets"})
    assert is_binary(message_event_id)

    # --- dana (now joined) can find the message via search ---
    search_body = %{"search_categories" => %{"room_events" => %{"search_term" => unique_phrase}}}
    dana_search_conn = authed(dana.token) |> jp("/_matrix/client/v3/search", search_body)
    dana_results = decode(dana_search_conn)["search_categories"]["room_events"]["results"]
    assert Enum.any?(dana_results, &(get_in(&1, ["result", "event_id"]) == message_event_id))

    # --- stranger (never joined) finds nothing, even for the same term ---
    stranger_search_conn = authed(stranger.token) |> jp("/_matrix/client/v3/search", search_body)
    assert decode(stranger_search_conn)["search_categories"]["room_events"]["results"] == []

    # --- alice unpublishes the room; it drops out of the directory ---
    unpublish_conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/directory/list/room/#{room_id}", %{"visibility" => "private"})

    assert unpublish_conn.status == 200

    after_conn =
      authed(stranger.token)
      |> jp("/_matrix/client/v3/publicRooms", %{"filter" => %{"generic_search_term" => unique}})

    refute Enum.any?(decode(after_conn)["chunk"], &(&1["room_id"] == room_id))

    # --- but the alias itself still resolves (unpublishing != removing the alias) ---
    resolve_conn = build_conn() |> get("/_matrix/client/v3/directory/room/#{encode_alias(room_alias)}")
    assert resolve_conn.status == 200
    assert decode(resolve_conn)["room_id"] == room_id
  end
end
