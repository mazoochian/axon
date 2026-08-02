defmodule AxonWeb.AppService.ProvisioningTest do
  @moduledoc """
  Regression coverage for on-demand provisioning: the homeserver asks an
  AS to lazily create a user/room it doesn't know about yet, via
  `GET /_matrix/app/v1/users/:userId` and `GET /_matrix/app/v1/rooms/:roomAlias`,
  before giving up and answering not-found.
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

  defp put_registration(reg), do: :ets.insert(@table, {:registrations, [reg]})

  defp registration(id, port) do
    %{
      "id" => id,
      "url" => "http://127.0.0.1:#{port}",
      "as_token" => "as-token-#{id}",
      "hs_token" => "hs-token-#{id}",
      "sender_localpart" => "_#{id}_bot",
      "namespaces" => %{
        "users" => [%{"regex" => "@#{id}_.*", "exclusive" => true}],
        "aliases" => [%{"regex" => "##{id}_.*", "exclusive" => true}],
        "rooms" => []
      }
    }
  end

  describe "GET /_matrix/client/v3/profile/:user_id" do
    test "an unknown user matching an AS namespace triggers a provisioning query, then succeeds if the AS creates it" do
      port = 19_660
      start_supervised!({FakeAppService, port: port})
      reg = registration("prov1", port)
      put_registration(reg)

      user_id = "@prov1_ghost:localhost"

      # A real bridge registers the ghost synchronously, inside its own
      # query-handler, before replying 200 — reproduced for real here via
      # `put_response_fn/5`, which runs in the Bandit request process and
      # shares this test's sandboxed DB connection.
      FakeAppService.put_response_fn(
        port,
        {"GET", "/_matrix/app/v1/users/#{URI.encode(user_id)}"},
        200,
        %{},
        fn ->
          build_conn()
          |> put_req_header("authorization", "Bearer #{reg["as_token"]}")
          |> put_req_header("content-type", "application/json")
          |> post(
            "/_matrix/client/v3/register",
            Jason.encode!(%{"type" => "m.login.application_service", "username" => "prov1_ghost"})
          )
        end
      )

      conn = build_conn() |> get("/_matrix/client/v3/profile/#{user_id}")
      assert conn.status == 200

      [request] = FakeAppService.requests(port)
      assert request.path == "/_matrix/app/v1/users/#{user_id}"
      assert {"authorization", "Bearer hs-token-prov1"} in request.headers
    end

    test "an unknown user matching an AS namespace stays not-found if the AS declines (404)" do
      port = 19_661
      start_supervised!({FakeAppService, port: port})
      reg = registration("prov2", port)
      put_registration(reg)

      user_id = "@prov2_ghost:localhost"
      FakeAppService.user_query_response(port, user_id, 404)

      conn = build_conn() |> get("/_matrix/client/v3/profile/#{user_id}")
      assert conn.status == 404
    end

    test "an unknown user matching no AS namespace never triggers a query" do
      port = 19_662
      start_supervised!({FakeAppService, port: port})
      put_registration(registration("prov3", port))

      conn = build_conn() |> get("/_matrix/client/v3/profile/@unrelated:localhost")
      assert conn.status == 404
      assert FakeAppService.requests(port) == []
    end
  end

  describe "GET /_matrix/client/v3/directory/room/:room_alias (and join-by-alias)" do
    test "an unknown alias matching an AS namespace triggers a provisioning query, then resolves if the AS creates the room" do
      port = 19_663
      start_supervised!({FakeAppService, port: port})
      reg = registration("prov4", port)
      put_registration(reg)

      encoded_alias = "%23prov4_room:localhost"

      # A real bridge creates the room + alias synchronously, inside its own
      # query-handler, before replying 200 — reproduced for real via
      # `put_response_fn/5` (see the profile test above for why).
      FakeAppService.put_response_fn(
        port,
        {"GET", "/_matrix/app/v1/rooms/#{encoded_alias}"},
        200,
        %{},
        fn ->
          as_conn =
            authed(reg["as_token"])
            |> jp("/_matrix/client/v3/createRoom", %{"preset" => "public_chat"})

          room_id = decode(as_conn)["room_id"]

          authed(reg["as_token"])
          |> jpu("/_matrix/client/v3/directory/room/#{encoded_alias}", %{"room_id" => room_id})
        end
      )

      conn = build_conn() |> get("/_matrix/client/v3/directory/room/#{encoded_alias}")
      assert conn.status == 200
      assert decode(conn)["room_id"]

      [request] = FakeAppService.requests(port)
      assert request.path == "/_matrix/app/v1/rooms/#{encoded_alias}"
    end

    test "an unknown alias matching an AS namespace stays not-found if the AS declines" do
      port = 19_664
      start_supervised!({FakeAppService, port: port})
      reg = registration("prov5", port)
      put_registration(reg)

      room_alias = "#prov5_room:localhost"
      FakeAppService.room_query_response(port, room_alias, 404)

      conn = build_conn() |> get("/_matrix/client/v3/directory/room/%23prov5_room:localhost")
      assert conn.status == 404
    end
  end
end
