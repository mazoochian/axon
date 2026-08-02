defmodule AxonWeb.AppService.RateLimitExemptionTest do
  @moduledoc """
  Regression coverage for the Application Service rate-limit exemption in
  `AxonWeb.Plug.RateLimit`: an AS's own `sender_localpart` traffic is
  always exempt, and masqueraded-user traffic is exempt unless the
  registration sets `rate_limited: true`.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers

  @table :axon_appservices

  setup do
    :ets.insert(@table, {:registrations, []})
    original = Application.get_env(:axon_web, :rate_limits)

    on_exit(fn ->
      :ets.insert(@table, {:registrations, []})
      Application.put_env(:axon_web, :rate_limits, original)
    end)

    Application.put_env(
      :axon_web,
      :rate_limits,
      Keyword.put(original, :send_event, max: 1, window_ms: 60_000)
    )

    :ok
  end

  defp put_registration(reg), do: :ets.insert(@table, {:registrations, [reg]})

  defp registration(id, rate_limited) do
    %{
      "id" => id,
      "url" => "http://127.0.0.1:1",
      "as_token" => "as-token-#{id}",
      "hs_token" => "hs-token-#{id}",
      "sender_localpart" => "_#{id}_bot",
      "rate_limited" => rate_limited,
      "namespaces" => %{
        "users" => [%{"regex" => "@#{id}_.*", "exclusive" => true}],
        "aliases" => [],
        "rooms" => []
      }
    }
  end

  defp send_n(token, room_id, n) do
    Enum.map(1..n, fn i ->
      send_event_raw(token, room_id, %{"body" => "msg#{i}"})
    end)
  end

  defp send_event_raw(token, room_id, content) do
    txn_id = "txn_#{System.unique_integer([:positive])}"

    authed(token)
    |> jpu("/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn_id}", content)
  end

  test "an ordinary user is rate-limited by the configured send_event bucket" do
    user = register("rl_plain_#{System.unique_integer([:positive])}")
    room_id = create_room(user.token)
    :ets.match_delete(:axon_rate_limiter, {{:send_event, :_}, :_})

    [conn1, conn2] = send_n(user.token, room_id, 2)
    assert conn1.status == 200
    assert conn2.status == 429
  end

  test "the AS's own sender_localpart traffic is always exempt, even with rate_limited: true" do
    reg = registration("rlex1", true)
    put_registration(reg)

    conn =
      authed(reg["as_token"]) |> jp("/_matrix/client/v3/createRoom", %{"preset" => "public_chat"})

    room_id = decode(conn)["room_id"]
    :ets.match_delete(:axon_rate_limiter, {{:send_event, :_}, :_})

    results = send_n(reg["as_token"], room_id, 5)
    assert Enum.all?(results, &(&1.status == 200))
  end

  test "masqueraded-user traffic is exempt when rate_limited: false" do
    reg = registration("rlex2", false)
    put_registration(reg)
    ghost = "@rlex2_ghost:localhost"

    conn =
      authed(reg["as_token"])
      |> jp("/_matrix/client/v3/createRoom?user_id=#{ghost}", %{"preset" => "public_chat"})

    room_id = decode(conn)["room_id"]
    :ets.match_delete(:axon_rate_limiter, {{:send_event, :_}, :_})

    results =
      Enum.map(1..5, fn i ->
        txn_id = "txn_#{System.unique_integer([:positive])}"

        build_conn()
        |> put_req_header("authorization", "Bearer #{reg["as_token"]}")
        |> put_req_header("content-type", "application/json")
        |> put(
          "/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn_id}?user_id=#{ghost}",
          Jason.encode!(%{"body" => "msg#{i}"})
        )
      end)

    assert Enum.all?(results, &(&1.status == 200))
  end

  test "masqueraded-user traffic is still rate-limited when rate_limited: true" do
    reg = registration("rlex3", true)
    put_registration(reg)
    ghost = "@rlex3_ghost:localhost"

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{reg["as_token"]}")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/_matrix/client/v3/createRoom?user_id=#{ghost}",
        Jason.encode!(%{"preset" => "public_chat"})
      )

    room_id = decode(conn)["room_id"]
    :ets.match_delete(:axon_rate_limiter, {{:send_event, :_}, :_})

    results =
      Enum.map(1..2, fn i ->
        txn_id = "txn_#{System.unique_integer([:positive])}"

        build_conn()
        |> put_req_header("authorization", "Bearer #{reg["as_token"]}")
        |> put_req_header("content-type", "application/json")
        |> put(
          "/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{txn_id}?user_id=#{ghost}",
          Jason.encode!(%{"body" => "msg#{i}"})
        )
      end)

    statuses = Enum.map(results, & &1.status)
    assert 429 in statuses
  end
end
