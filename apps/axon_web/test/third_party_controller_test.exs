defmodule AxonWeb.ThirdPartyControllerTest do
  @moduledoc """
  Regression coverage for the Client-Server API "Third party networks"
  endpoints (`GET /thirdparty/protocols`, `/protocol/:protocol`,
  `/user[/:protocol]`, `/location[/:protocol]`). Axon holds no third-party
  state itself — every response is proxied to whichever registered
  Application Service declares the relevant `protocols` entry, or (for the
  two reverse lookups) owns the queried mxid/alias via its `users`/
  `aliases` namespace.

  Registrations are written straight into `AxonWeb.AppService.Manager`'s
  backing ETS table (`:public`, `:named_table`) rather than by restarting
  the singleton manager with a config file, the same way
  `app_service_manager_test.exs` already does.
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
        "users" => ns(Keyword.get(opts, :users_regex)),
        "aliases" => ns(Keyword.get(opts, :aliases_regex)),
        "rooms" => []
      }
    }
  end

  defp ns(nil), do: []
  defp ns(regex), do: [%{"regex" => regex, "exclusive" => false}]

  defp user_conn do
    register("tp_user_#{System.unique_integer([:positive])}").token
  end

  defp get_auth(token, path), do: authed(token) |> get(path)

  describe "GET /thirdparty/protocols" do
    test "aggregates protocol metadata across every registered AS" do
      port = 19_820
      start_supervised!({FakeAppService, port: port})

      FakeAppService.thirdparty_protocol_response(port, "irc", 200, %{
        "user_fields" => ["nick"],
        "location_fields" => ["channel"],
        "field_types" => %{},
        "instances" => []
      })

      put_registrations([registration("tp1", port, protocols: ["irc"])])

      conn = get_auth(user_conn(), "/_matrix/client/v3/thirdparty/protocols")

      assert conn.status == 200
      body = decode(conn)
      assert body["irc"]["user_fields"] == ["nick"]
      assert body["irc"]["location_fields"] == ["channel"]
    end

    test "no registered AS declares any protocol means an empty object" do
      conn = get_auth(user_conn(), "/_matrix/client/v3/thirdparty/protocols")

      assert conn.status == 200
      assert decode(conn) == %{}
    end
  end

  describe "GET /thirdparty/protocol/:protocol" do
    test "returns the metadata the AS reports for a known protocol" do
      port = 19_821
      start_supervised!({FakeAppService, port: port})
      FakeAppService.thirdparty_protocol_response(port, "gitter", 200, %{"user_fields" => []})
      put_registrations([registration("tp2", port, protocols: ["gitter"])])

      conn = get_auth(user_conn(), "/_matrix/client/v3/thirdparty/protocol/gitter")

      assert conn.status == 200
      assert decode(conn)["user_fields"] == []
    end

    test "404s M_NOT_FOUND when no registered AS declares that protocol" do
      conn = get_auth(user_conn(), "/_matrix/client/v3/thirdparty/protocol/nonexistent")

      assert conn.status == 404
      assert decode(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "the AS's hs_token is what authenticates the outbound query" do
      port = 19_822
      start_supervised!({FakeAppService, port: port})
      FakeAppService.thirdparty_protocol_response(port, "irc", 200, %{})
      put_registrations([registration("tp3", port, protocols: ["irc"])])

      assert get_auth(user_conn(), "/_matrix/client/v3/thirdparty/protocol/irc").status == 200

      [req] = FakeAppService.requests(port)
      assert {"authorization", "Bearer hs-token-tp3"} in req.headers
    end
  end

  describe "GET /thirdparty/user (reverse lookup)" do
    test "asks the AS whose users namespace owns the mxid and returns its answer" do
      port = 19_823
      start_supervised!({FakeAppService, port: port})

      FakeAppService.thirdparty_user_response(port, nil, 200, [
        %{
          "userid" => "@tp_irc_ghost:localhost",
          "protocol" => "irc",
          "fields" => %{"nick" => "bob"}
        }
      ])

      put_registrations([registration("tp4", port, users_regex: "@tp_irc_.*")])

      conn =
        get_auth(user_conn(), "/_matrix/client/v3/thirdparty/user?userid=@tp_irc_ghost:localhost")

      assert conn.status == 200
      assert [%{"fields" => %{"nick" => "bob"}}] = decode(conn)

      [req] = FakeAppService.requests(port)
      assert req.query["userid"] == "@tp_irc_ghost:localhost"
    end

    test "no owning AS returns an empty list rather than an error" do
      conn = get_auth(user_conn(), "/_matrix/client/v3/thirdparty/user?userid=@unowned:localhost")

      assert conn.status == 200
      assert decode(conn) == []
    end

    test "a missing userid is a 400 M_MISSING_PARAM" do
      conn = get_auth(user_conn(), "/_matrix/client/v3/thirdparty/user")

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_MISSING_PARAM"
    end
  end

  describe "GET /thirdparty/user/:protocol (forward lookup)" do
    test "forwards the protocol's search fields to the AS providing it" do
      port = 19_824
      start_supervised!({FakeAppService, port: port})

      FakeAppService.thirdparty_user_response(port, "irc", 200, [
        %{
          "userid" => "@tp_irc_alice:localhost",
          "protocol" => "irc",
          "fields" => %{"nick" => "alice"}
        }
      ])

      put_registrations([registration("tp5", port, protocols: ["irc"])])

      conn = get_auth(user_conn(), "/_matrix/client/v3/thirdparty/user/irc?nick=alice")

      assert conn.status == 200
      assert [%{"userid" => "@tp_irc_alice:localhost"}] = decode(conn)

      [req] = FakeAppService.requests(port)
      assert req.query["nick"] == "alice"
      # The :protocol path parameter Phoenix merges into params, and axon's
      # own access_token, must not leak into the bridge-facing query string.
      refute Map.has_key?(req.query, "protocol")
      refute Map.has_key?(req.query, "access_token")
    end

    test "404s M_NOT_FOUND for a protocol no AS declares" do
      conn = get_auth(user_conn(), "/_matrix/client/v3/thirdparty/user/nonexistent?nick=x")

      assert conn.status == 404
      assert decode(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "an unreachable AS degrades to an empty list rather than a server error" do
      # Nothing is listening on this port, so every request fails to connect.
      put_registrations([registration("tp6", 19_899, protocols: ["deadbridge"])])

      conn = get_auth(user_conn(), "/_matrix/client/v3/thirdparty/user/deadbridge?nick=x")

      assert conn.status == 200
      assert decode(conn) == []
    end

    test "an AS answering with a non-list body degrades to an empty list" do
      port = 19_825
      start_supervised!({FakeAppService, port: port})
      FakeAppService.thirdparty_user_response(port, "irc", 200, %{"not" => "a list"})
      put_registrations([registration("tp7", port, protocols: ["irc"])])

      conn = get_auth(user_conn(), "/_matrix/client/v3/thirdparty/user/irc?nick=x")

      assert conn.status == 200
      assert decode(conn) == []
    end
  end

  describe "GET /thirdparty/location" do
    test "the reverse lookup asks the AS whose aliases namespace owns the alias" do
      port = 19_826
      start_supervised!({FakeAppService, port: port})

      FakeAppService.thirdparty_location_response(port, nil, 200, [
        %{
          "alias" => "#tp_irc_room:localhost",
          "protocol" => "irc",
          "fields" => %{"channel" => "#general"}
        }
      ])

      put_registrations([registration("tp8", port, aliases_regex: "#tp_irc_.*")])

      conn =
        get_auth(
          user_conn(),
          "/_matrix/client/v3/thirdparty/location?alias=%23tp_irc_room:localhost"
        )

      assert conn.status == 200
      assert [%{"fields" => %{"channel" => "#general"}}] = decode(conn)
    end

    test "the forward lookup forwards search fields to the AS providing the protocol" do
      port = 19_827
      start_supervised!({FakeAppService, port: port})

      FakeAppService.thirdparty_location_response(port, "irc", 200, [
        %{
          "alias" => "#tp_irc_general:localhost",
          "protocol" => "irc",
          "fields" => %{"channel" => "#general"}
        }
      ])

      put_registrations([registration("tp9", port, protocols: ["irc"])])

      conn =
        get_auth(user_conn(), "/_matrix/client/v3/thirdparty/location/irc?channel=%23general")

      assert conn.status == 200
      assert [%{"alias" => "#tp_irc_general:localhost"}] = decode(conn)

      [req] = FakeAppService.requests(port)
      assert req.query["channel"] == "#general"
    end

    test "a missing alias on the reverse lookup is a 400 M_MISSING_PARAM" do
      conn = get_auth(user_conn(), "/_matrix/client/v3/thirdparty/location")

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_MISSING_PARAM"
    end

    test "404s M_NOT_FOUND for a protocol no AS declares" do
      conn = get_auth(user_conn(), "/_matrix/client/v3/thirdparty/location/nonexistent?x=1")

      assert conn.status == 404
      assert decode(conn)["errcode"] == "M_NOT_FOUND"
    end
  end

  describe "unauthenticated access" do
    test "the third-party endpoints sit behind the authenticated CS pipeline" do
      conn = build_conn() |> get("/_matrix/client/v3/thirdparty/protocols")
      assert conn.status == 401
    end
  end
end
