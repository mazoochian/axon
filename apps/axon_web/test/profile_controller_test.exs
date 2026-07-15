defmodule AxonWeb.ProfileControllerTest do
  @moduledoc """
  Direct coverage for `AxonWeb.ProfileController` branches not exercised by
  `AxonWeb.ProfilePropagationTest` (displayname propagation happy path) or
  `AxonWeb.ProfileRemoteTest` (federation proxying): the empty-profile show
  response, the avatar_url mutator, ownership checks, missing-param
  fallbacks, and malformed/unregistered user_id lookups.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  test "GET /profile/:user_id with no displayname/avatar_url set returns an empty object" do
    alice = register("emptyprofile_#{System.unique_integer([:positive])}")

    # Registration seeds displayname to the localpart by default — clear
    # both fields directly to exercise show/2's "field absent" branches.
    {:ok, _} =
      AxonCore.UserStore.update_profile(alice.user_id, %{displayname: nil, avatar_url: nil})

    conn = authed(alice.token) |> get("/_matrix/client/v3/profile/#{alice.user_id}")

    assert conn.status == 200
    assert decode(conn) == %{}
  end

  test "GET /profile/:user_id for a syntactically malformed user_id (no colon) 404s" do
    alice = register("malformedlookup_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/profile/not-a-valid-user-id")

    assert conn.status == 404
  end

  test "GET /profile/:user_id for a well-formed but unregistered local user_id 404s" do
    alice = register("lookupmissing_#{System.unique_integer([:positive])}")
    conn = authed(alice.token) |> get("/_matrix/client/v3/profile/@nobody_here:localhost")

    assert conn.status == 404
  end

  test "PUT displayname on another user's profile is forbidden" do
    alice = register("dnowner_#{System.unique_integer([:positive])}")
    bob = register("dnother_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/profile/#{bob.user_id}/displayname", %{
        "displayname" => "Hijacked"
      })

    assert conn.status == 403
    assert decode(conn)["errcode"] == "M_FORBIDDEN"
  end

  test "PUT displayname with no displayname field in the body is a no-op success" do
    alice = register("dnmissing_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/profile/#{alice.user_id}/displayname", %{})

    assert conn.status == 200
    assert decode(conn) == %{}
  end

  test "GET avatar_url reflects what was set via PUT, and propagates" do
    alice = register("avowner_#{System.unique_integer([:positive])}")

    put_conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/profile/#{alice.user_id}/avatar_url", %{
        "avatar_url" => "mxc://localhost/abc123"
      })

    assert put_conn.status == 200

    get_conn =
      authed(alice.token) |> get("/_matrix/client/v3/profile/#{alice.user_id}/avatar_url")

    assert decode(get_conn)["avatar_url"] == "mxc://localhost/abc123"
  end

  test "PUT avatar_url on another user's profile is forbidden" do
    alice = register("avowner2_#{System.unique_integer([:positive])}")
    bob = register("avother_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/profile/#{bob.user_id}/avatar_url", %{
        "avatar_url" => "mxc://localhost/hijacked"
      })

    assert conn.status == 403
    assert decode(conn)["errcode"] == "M_FORBIDDEN"
  end

  test "PUT avatar_url with no avatar_url field in the body is a no-op success" do
    alice = register("avmissing_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jpu("/_matrix/client/v3/profile/#{alice.user_id}/avatar_url", %{})

    assert conn.status == 200
    assert decode(conn) == %{}
  end
end
