defmodule AxonWeb.ThirdPartyControllerTest do
  @moduledoc """
  Regression coverage for the Client-Server API "Third party networks"
  endpoints (`GET /thirdparty/protocols`, `/protocol/:protocol`,
  `/user[/:protocol]`, `/location[/:protocol]`) — every response is
  proxied to whichever registered Application Service declares the
  relevant `protocols` entry, or (for the reverse lookups) owns the
  queried mxid/alias via its `users`/`aliases` namespace.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  alias AxonWeb.FakeAppService

  @table :axon_appservices

  setup do
    :ets.insert(@table, {:registrations, []})
    on_exit(fn -> :ets.insert(@table, {:registrations, []}) end)
    :ok
  end

  defp put_registrations(regs), do: :ets.insert(@table, {:registrations, regs})

  defp registration(id, port, opts) do
    %{
      "id" => id,
      "url" => "http://127.0.0.1:#{port}",
      "as_token" => "as-token-#{id}",
      "hs_token" => "hs-token-#{id}",
      "sender_localpart" => "_#{id}_bot",
      "protocols" => Keyword.get(opts, :protocols, []),
      "namespaces" => %{
        "users" => Keyword.get(opts, :users_regex, nil) |> ns(),
        "aliases" => Keyword.get(opts, :aliases_regex, nil) |> ns(),
        "rooms" => []
      }
    }
  end

  defp ns(nil), do: []
  defp ns(regex), do: [%{"regex" => regex, "exclusive" => false}]

  defp get_auth(token, path), do: authed(token) |> get(path)

  describe "GET /thirdparty/protocols" do
    test "aggregates protocol metadata across every registered AS" do
      port = 19_800
      start_supervised!({FakeAppService, port: port})

      FakeAppService.thirdparty_protocol_response(port, "irc", 200, %{
        "user_fields" => ["nick"],
        "location_fields" => ["channel"],
        "field_types" => %{},
        "instances" => []
      })

      put_registrations([registration("tp1", port, protocols: ["irc"])])

      user = register("tp_user1_#{System.unique_integer([:positive])}")
      conn = get_auth(user.token, "/_matrix/client/v3/thirdparty/protocols")

      assert conn.status == 200
      body = decode(conn)
      assert body["irc"]["user_fields"] == ["nick"]
    end

    test "no registered AS declares any protocol means an empty object" do
      user = register("tp_user2_#{System.unique_integer([:positive])}")
      conn = get_auth(user.token, "/_matrix/client/v3/thirdparty/protocols")

      assert conn.status == 200
      assert decode(conn) == %{}
    end
  end

  describe "GET /thirdparty/protocol/:protocol" do
    test "returns the metadata for a known protocol" do
      port = 19_801
      start_supervised!({FakeAppService, port: port})
      FakeAppService.thirdparty_protocol_response(port, "gitter", 200, %{"user_fields" => []})
      put_registrations([registration("tp2", port, protocols: ["gitter"])])

      user = register("tp_user3_#{System.unique_integer([:positive])}")
      conn = get_auth(user.token, "/_matrix/client/v3/thirdparty/protocol/gitter")

      assert conn.status == 200
      assert decode(conn)["user_fields"] == []
    end

    test "404s for an unknown protocol" do
      user = register("tp_user4_#{System.unique_integer([:positive])}")
      conn = get_auth(user.token, "/_matrix/client/v3/thirdparty/protocol/nonexistent")

      assert conn.status == 404
      assert decode(conn)["errcode"] == "M_NOT_FOUND"
    end
  end

  describe "GET /thirdparty/user (reverse lookup)" do
    test "asks the AS that owns the given user_id and returns its answer" do
      port = 19_810
      start_supervised!({FakeAppService, port: port})

      FakeAppService.thirdparty_user_response(port, nil, 200, [
        %{
          "userid" => "@tp_irc_ghost:localhost",
          "protocol" => "irc",
          "fields" => %{"nick" => "bob"}
        }
      ])

      put_registrations([registration("tp3", port, users_regex: "@tp_irc_.*")])

      user = register("tp_user5_#{System.unique_integer([:positive])}")

      conn =
        get_auth(
          user.token,
          "/_matrix/client/v3/thirdparty/user?userid=@tp_irc_ghost:localhost"
        )

      assert conn.status == 200
      [entry] = decode(conn)
      assert entry["fields"]["nick"] == "bob"
    end

    test "no owning AS returns an empty list, not an error" do
      user = register("tp_user6_#{System.unique_integer([:positive])}")

      conn =
        get_auth(user.token, "/_matrix/client/v3/thirdparty/user?userid=@unowned:localhost")

      assert conn.status == 200
      assert decode(conn) == []
    end

    test "missing userid is a 400 M_MISSING_PARAM" do
      user = register("tp_user7_#{System.unique_integer([:positive])}")
      conn = get_auth(user.token, "/_matrix/client/v3/thirdparty/user")

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_MISSING_PARAM"
    end
  end

  describe "GET /thirdparty/user/:protocol (forward lookup)" do
    test "forwards search fields to the AS providing that protocol" do
      port = 19_811
      start_supervised!({FakeAppService, port: port})

      FakeAppService.thirdparty_user_response(port, "irc", 200, [
        %{
          "userid" => "@tp_irc_alice:localhost",
          "protocol" => "irc",
          "fields" => %{"nick" => "alice"}
        }
      ])

      put_registrations([registration("tp4", port, protocols: ["irc"])])

      user = register("tp_user8_#{System.unique_integer([:positive])}")
      conn = get_auth(user.token, "/_matrix/client/v3/thirdparty/user/irc?nick=alice")

      assert conn.status == 200
      [entry] = decode(conn)
      assert entry["userid"] == "@tp_irc_alice:localhost"
    end

    test "404s for an unknown protocol" do
      user = register("tp_user9_#{System.unique_integer([:positive])}")
      conn = get_auth(user.token, "/_matrix/client/v3/thirdparty/user/nonexistent?nick=x")

      assert conn.status == 404
      assert decode(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "an unreachable AS degrades to an empty list rather than a server error" do
      # No FakeAppService started for this port — every request will fail
      # to connect.
      put_registrations([registration("tp5", 19_999, protocols: ["deadbridge"])])

      user = register("tp_user10_#{System.unique_integer([:positive])}")
      conn = get_auth(user.token, "/_matrix/client/v3/thirdparty/user/deadbridge?nick=x")

      assert conn.status == 200
      assert decode(conn) == []
    end
  end

  describe "GET /thirdparty/location (reverse) and /thirdparty/location/:protocol (forward)" do
    test "reverse lookup asks the AS that owns the given alias" do
      port = 19_820
      start_supervised!({FakeAppService, port: port})

      FakeAppService.thirdparty_location_response(port, nil, 200, [
        %{
          "alias" => "#tp_irc_room:localhost",
          "protocol" => "irc",
          "fields" => %{"channel" => "#general"}
        }
      ])

      put_registrations([registration("tp6", port, aliases_regex: "#tp_irc_.*")])

      user = register("tp_user11_#{System.unique_integer([:positive])}")

      conn =
        get_auth(
          user.token,
          "/_matrix/client/v3/thirdparty/location?alias=%23tp_irc_room:localhost"
        )

      assert conn.status == 200
      [entry] = decode(conn)
      assert entry["fields"]["channel"] == "#general"
    end

    test "forward lookup forwards search fields to the AS providing that protocol" do
      port = 19_821
      start_supervised!({FakeAppService, port: port})

      FakeAppService.thirdparty_location_response(port, "irc", 200, [
        %{
          "alias" => "#tp_irc_general:localhost",
          "protocol" => "irc",
          "fields" => %{"channel" => "#general"}
        }
      ])

      put_registrations([registration("tp7", port, protocols: ["irc"])])

      user = register("tp_user12_#{System.unique_integer([:positive])}")
      conn = get_auth(user.token, "/_matrix/client/v3/thirdparty/location/irc?channel=%23general")

      assert conn.status == 200
      [entry] = decode(conn)
      assert entry["alias"] == "#tp_irc_general:localhost"
    end

    test "missing alias on the reverse lookup is a 400 M_MISSING_PARAM" do
      user = register("tp_user13_#{System.unique_integer([:positive])}")
      conn = get_auth(user.token, "/_matrix/client/v3/thirdparty/location")

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_MISSING_PARAM"
    end
  end
end
