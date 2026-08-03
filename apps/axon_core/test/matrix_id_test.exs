defmodule AxonCore.MatrixIdTest do
  @moduledoc """
  The explicit-port case is the whole reason this module exists: Complement
  addresses every remote homeserver as `host.docker.internal:<port>`, and the
  previous `String.split(id, ":") |> List.last()` returned the *port* for such
  an ID. Federation endpoints compared that against the requesting origin and
  rejected it, so no peer on a non-default port could join, invite, or be
  queried.
  """

  use ExUnit.Case, async: true

  doctest AxonCore.MatrixId

  alias AxonCore.MatrixId

  describe "server_name/1" do
    test "plain server name" do
      assert MatrixId.server_name("@alice:example.com") == "example.com"
    end

    test "server name with an explicit port keeps the port" do
      assert MatrixId.server_name("@alice:example.com:8448") == "example.com:8448"
      assert MatrixId.server_name("@charlie:host.docker.internal:41491") ==
               "host.docker.internal:41491"
    end

    test "works for every identifier sigil, not just user IDs" do
      assert MatrixId.server_name("!room:example.com:8448") == "example.com:8448"
      assert MatrixId.server_name("#alias:example.com:8448") == "example.com:8448"
    end

    test "IPv6 literal server names survive" do
      assert MatrixId.server_name("@alice:[::1]:8448") == "[::1]:8448"
    end

    test "a room-v12 room ID has no server part" do
      # MSC4291: a v12 room ID is its create event's reference hash, with no
      # :server suffix at all.
      assert MatrixId.server_name("!aBcD1234hashonly") == nil
    end

    test "malformed or non-binary input yields nil rather than raising" do
      assert MatrixId.server_name("@alice:") == nil
      assert MatrixId.server_name("") == nil
      assert MatrixId.server_name(nil) == nil
      assert MatrixId.server_name(:not_a_string) == nil
    end
  end

  describe "from_server?/2" do
    test "matches on the full server name including port" do
      assert MatrixId.from_server?("@alice:example.com:8448", "example.com:8448")
      refute MatrixId.from_server?("@alice:example.com:8448", "example.com")
      refute MatrixId.from_server?("@alice:example.com:8448", "8448")
    end

    test "an ID with no server part belongs to nobody" do
      refute MatrixId.from_server?("!hashonly", "example.com")
    end
  end
end
