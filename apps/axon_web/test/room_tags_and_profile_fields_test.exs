defmodule AxonWeb.RoomTagsAndProfileFieldsTest do
  @moduledoc """
  Regression tests for two previously-missing Client-Server API surfaces:

    * Room tagging (https://spec.matrix.org/v1.18/client-server-api/#room-tagging)
      — GET/PUT/DELETE /_matrix/client/v3/user/:user_id/rooms/:room_id/tags[/:tag]

    * Generic profile fields (https://spec.matrix.org/v1.18/client-server-api/#profiles,
      stable since Matrix 1.16) — GET/PUT/DELETE
      /_matrix/client/v3/profile/:user_id/:key_name
  """

  use AxonWeb.ConnCase, async: false

  defp register(username) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/register",
        Jason.encode!(%{
          "username" => username,
          "password" => "Test1234!",
          "kind" => "user",
          "auth" => %{"type" => "m.login.dummy"}
        })
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    %{token: body["access_token"], user_id: body["user_id"]}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp jp(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp jpu(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> put(path, Jason.encode!(body))

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp create_room(token) do
    conn = authed(token) |> jp("/_matrix/client/v3/createRoom", %{})
    assert conn.status == 200
    decode(conn)["room_id"]
  end

  defp sync(token) do
    conn = authed(token) |> get("/_matrix/client/v3/sync?timeout=0")
    assert conn.status == 200
    decode(conn)
  end

  defp uniq(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  # ---------------------------------------------------------------------------
  # Room tags
  # ---------------------------------------------------------------------------

  test "set, list, and delete a room tag" do
    alice = register(uniq("alice"))
    room_id = create_room(alice.token)

    tags_path = "/_matrix/client/v3/user/#{alice.user_id}/rooms/#{room_id}/tags"

    # Initially empty
    get_conn = authed(alice.token) |> get(tags_path)
    assert get_conn.status == 200
    assert decode(get_conn)["tags"] == %{}

    # Set m.favourite
    put_conn = authed(alice.token) |> jpu("#{tags_path}/m.favourite", %{})
    assert put_conn.status == 200

    list_conn = authed(alice.token) |> get(tags_path)
    assert %{"m.favourite" => %{}} = decode(list_conn)["tags"]

    # Delete it
    del_conn = authed(alice.token) |> delete("#{tags_path}/m.favourite")
    assert del_conn.status == 200

    final_conn = authed(alice.token) |> get(tags_path)
    assert decode(final_conn)["tags"] == %{}
  end

  test "tag order round-trips" do
    alice = register(uniq("alice"))
    room_id = create_room(alice.token)
    tags_path = "/_matrix/client/v3/user/#{alice.user_id}/rooms/#{room_id}/tags"

    put_conn = authed(alice.token) |> jpu("#{tags_path}/m.lowpriority", %{"order" => 0.25})
    assert put_conn.status == 200

    get_conn = authed(alice.token) |> get(tags_path)
    assert decode(get_conn)["tags"]["m.lowpriority"]["order"] == 0.25
  end

  test "setting one tag does not clobber another already-set tag" do
    alice = register(uniq("alice"))
    room_id = create_room(alice.token)
    tags_path = "/_matrix/client/v3/user/#{alice.user_id}/rooms/#{room_id}/tags"

    authed(alice.token) |> jpu("#{tags_path}/m.favourite", %{"order" => 0.1})
    authed(alice.token) |> jpu("#{tags_path}/u.custom_tag", %{"order" => 0.9})

    get_conn = authed(alice.token) |> get(tags_path)
    tags = decode(get_conn)["tags"]
    assert tags["m.favourite"]["order"] == 0.1
    assert tags["u.custom_tag"]["order"] == 0.9
  end

  test "deleting a tag that was never set is not an error" do
    alice = register(uniq("alice"))
    room_id = create_room(alice.token)
    tags_path = "/_matrix/client/v3/user/#{alice.user_id}/rooms/#{room_id}/tags"

    del_conn = authed(alice.token) |> delete("#{tags_path}/m.never_set")
    assert del_conn.status == 200
    assert decode(del_conn) == %{}
  end

  test "tags show up in /sync per-room account_data" do
    alice = register(uniq("alice"))
    room_id = create_room(alice.token)
    tags_path = "/_matrix/client/v3/user/#{alice.user_id}/rooms/#{room_id}/tags"

    put_conn = authed(alice.token) |> jpu("#{tags_path}/m.favourite", %{"order" => 0.5})
    assert put_conn.status == 200

    body = sync(alice.token)
    ad_events = get_in(body, ["rooms", "join", room_id, "account_data", "events"]) || []
    tag_event = Enum.find(ad_events, &(&1["type"] == "m.tag"))

    refute is_nil(tag_event)
    assert tag_event["content"]["tags"]["m.favourite"]["order"] == 0.5
  end

  test "another user's tags are refused with 403" do
    alice = register(uniq("alice"))
    bob = register(uniq("bob"))
    room_id = create_room(alice.token)
    tags_path = "/_matrix/client/v3/user/#{alice.user_id}/rooms/#{room_id}/tags"

    get_conn = authed(bob.token) |> get(tags_path)
    assert get_conn.status == 403
    assert decode(get_conn)["errcode"] == "M_FORBIDDEN"

    put_conn = authed(bob.token) |> jpu("#{tags_path}/m.favourite", %{})
    assert put_conn.status == 403

    del_conn = authed(bob.token) |> delete("#{tags_path}/m.favourite")
    assert del_conn.status == 403
  end

  # ---------------------------------------------------------------------------
  # Generic profile fields
  # ---------------------------------------------------------------------------

  test "set, get, and delete a custom profile field" do
    alice = register(uniq("alice"))

    put_conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/profile/#{alice.user_id}/m.tz", %{"m.tz" => "Europe/London"})

    assert put_conn.status == 200

    get_conn = authed(alice.token) |> get("/_matrix/client/v3/profile/#{alice.user_id}/m.tz")
    assert get_conn.status == 200
    assert decode(get_conn)["m.tz"] == "Europe/London"

    # Also appears in the whole-profile GET
    whole_conn = authed(alice.token) |> get("/_matrix/client/v3/profile/#{alice.user_id}")
    assert decode(whole_conn)["m.tz"] == "Europe/London"

    del_conn = authed(alice.token) |> delete("/_matrix/client/v3/profile/#{alice.user_id}/m.tz")
    assert del_conn.status == 200

    get_conn2 = authed(alice.token) |> get("/_matrix/client/v3/profile/#{alice.user_id}/m.tz")
    assert get_conn2.status == 404
  end

  test "deleting a profile field that was never set is not an error" do
    alice = register(uniq("alice"))

    del_conn =
      authed(alice.token)
      |> delete("/_matrix/client/v3/profile/#{alice.user_id}/com.example.never_set")

    assert del_conn.status == 200
    assert decode(del_conn) == %{}
  end

  test "cannot set another user's profile field" do
    alice = register(uniq("alice"))
    bob = register(uniq("bob"))

    put_conn =
      authed(bob.token)
      |> jpu("/_matrix/client/v3/profile/#{alice.user_id}/m.tz", %{"m.tz" => "UTC"})

    assert put_conn.status == 403
    assert decode(put_conn)["errcode"] == "M_FORBIDDEN"

    del_conn = authed(bob.token) |> delete("/_matrix/client/v3/profile/#{alice.user_id}/m.tz")
    assert del_conn.status == 403
  end

  test "displayname and avatar_url keep working through both the dedicated and generic routes" do
    alice = register(uniq("alice"))

    # Set via dedicated route
    dedicated_conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/profile/#{alice.user_id}/displayname", %{
        "displayname" => "Via Dedicated"
      })

    assert dedicated_conn.status == 200

    generic_get =
      authed(alice.token) |> get("/_matrix/client/v3/profile/#{alice.user_id}/displayname")

    assert decode(generic_get)["displayname"] == "Via Dedicated"

    # Set via generic route
    generic_put =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/profile/#{alice.user_id}/avatar_url", %{
        "avatar_url" => "mxc://example.org/abc123"
      })

    assert generic_put.status == 200

    dedicated_get =
      authed(alice.token) |> get("/_matrix/client/v3/profile/#{alice.user_id}/avatar_url")

    assert decode(dedicated_get)["avatar_url"] == "mxc://example.org/abc123"

    whole_conn = authed(alice.token) |> get("/_matrix/client/v3/profile/#{alice.user_id}")
    whole = decode(whole_conn)
    assert whole["displayname"] == "Via Dedicated"
    assert whole["avatar_url"] == "mxc://example.org/abc123"
  end
end
