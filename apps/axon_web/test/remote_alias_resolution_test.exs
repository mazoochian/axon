defmodule AxonWeb.RemoteAliasResolutionTest do
  @moduledoc """
  Regression test: joining a room by a remote alias (`#alias:otherserver`)
  must actually send the alias to the remote server's directory query.

  Found while wiring up Application Service alias provisioning (adjacent
  code, same "resolve an alias" territory) — `RoomController.resolve_remote_alias/3`
  built the outbound query URL with plain `URI.encode/1`, which doesn't
  escape `#`. Since a room_alias always starts with `#` (the URI fragment
  delimiter), and the URL string is later parsed via `URI.parse` when handed
  to Finch, everything from the `#` onward was silently dropped — every
  remote-alias join sent `room_alias=` (empty) to the remote server. Not
  introduced here; a real, previously-unnoticed bug now fixed alongside the
  Application Service work (`URI.encode_www_form/1` instead).
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonFederation.{FakeRemoteMatrixServer, KeyCache}

  @port 19_670
  @server_name "fake-alias.test"

  setup do
    start_supervised!({FakeRemoteMatrixServer, port: @port, server_name: @server_name})
    KeyCache.clear()

    Application.put_env(:axon_federation, :server_overrides, %{
      @server_name => "http://127.0.0.1:#{@port}"
    })

    on_exit(fn -> Application.delete_env(:axon_federation, :server_overrides) end)
    :ok
  end

  test "joining by a remote alias sends the alias intact to the remote server" do
    user = register("alias_join_#{System.unique_integer([:positive])}")
    room_alias = "#some_room:#{@server_name}"

    FakeRemoteMatrixServer.put_response(
      @port,
      {"GET", ~r{^/_matrix/federation/v1/query/directory}},
      404,
      %{"errcode" => "M_NOT_FOUND", "error" => "no such room"}
    )

    encoded_alias = "%23some_room:#{@server_name}"
    authed(user.token) |> post("/_matrix/client/v3/join/#{encoded_alias}")

    [request] =
      FakeRemoteMatrixServer.requests(@port)
      |> Enum.filter(&String.starts_with?(&1.path, "/_matrix/federation/v1/query/directory"))

    # The bug manifested as this query string being empty
    # ("room_alias=") regardless of what alias was requested.
    assert URI.decode_query(request.query_string)["room_alias"] == room_alias
  end
end
