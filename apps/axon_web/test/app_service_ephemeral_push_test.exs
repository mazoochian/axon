defmodule AxonWeb.AppService.EphemeralPushTest do
  @moduledoc """
  Regression coverage for AS ephemeral push (`receive_ephemeral: true`,
  spec's "Pushing ephemeral data"): `m.typing`, `m.receipt` (public and
  private), and `m.presence`, dispatched via
  `AxonWeb.AppService.Manager.dispatch_ephemeral/5` and delivered through
  the same `AxonWeb.AppService.OutboundQueue` as timeline events.

  Every test does its room/user setup (registration, `create_room`, an
  initial message to receipt) *before* registering the fixture AS, then
  registers it immediately before the one action actually under test. A
  `rooms: [".*"]` fixture (used to test room-namespace matching without
  depending on an unpredictable server-generated room_id) would otherwise
  also match every setup-step timeline event — `m.room.create`,
  membership, power levels, and so on — each becoming its own
  `AxonWeb.AppService.OutboundQueue` row and immediate delivery attempt.
  Enough of those firing at once can saturate the queue's per-destination
  concurrency cap (5, see its moduledoc) and push the one delivery a test
  actually cares about past the 5s sweep interval — not a functional bug,
  just self-inflicted noise from an intentionally-broad test fixture.
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
      "receive_ephemeral" => Keyword.get(opts, :receive_ephemeral, true),
      "namespaces" => %{
        "users" => Keyword.get(opts, :users_regex, nil) |> user_ns(),
        "aliases" => [],
        "rooms" => Keyword.get(opts, :rooms_regex, nil) |> room_ns()
      }
    }
  end

  defp user_ns(nil), do: []
  defp user_ns(regex), do: [%{"regex" => regex, "exclusive" => false}]
  defp room_ns(nil), do: []
  defp room_ns(regex), do: [%{"regex" => regex, "exclusive" => false}]

  defp wait_for(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        do_wait_for(fun, deadline)
    end
  end

  # Every authenticated request bumps the caller's presence, which
  # independently broadcasts its own m.presence push whenever an AS's
  # namespace happens to also cover this user/room — so always filter to
  # the specific ephemeral `type` (and, for presence, the specific state)
  # a test cares about, never assume the list holds exactly one entry.
  defp ephemeral_requests(port) do
    FakeAppService.requests(port)
    |> Enum.filter(&String.starts_with?(&1.path, "/_matrix/app/v1/transactions/"))
    |> Enum.flat_map(&(&1.body["ephemeral"] || []))
  end

  defp ephemeral_of_type(port, type) do
    Enum.filter(ephemeral_requests(port), &(&1["type"] == type))
  end

  describe "m.typing" do
    test "an AS with receive_ephemeral: true and a matching rooms namespace gets typing pushes" do
      port = 19_700
      start_supervised!({FakeAppService, port: port})
      FakeAppService.transaction_response(port, 200)

      user = register("eph_typer_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)

      put_registrations([registration("eph1", port, rooms_regex: ".*")])

      authed(user.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/typing/#{user.user_id}", %{
        "typing" => true,
        "timeout" => 30_000
      })

      assert wait_for(fn -> ephemeral_of_type(port, "m.typing") != [] end)
      [ev] = ephemeral_of_type(port, "m.typing")
      assert ev["room_id"] == room_id
      assert ev["content"]["user_ids"] == [user.user_id]
    end

    test "an AS without receive_ephemeral never gets typing pushes even with a matching namespace" do
      port = 19_701
      start_supervised!({FakeAppService, port: port})
      FakeAppService.transaction_response(port, 200)

      user = register("eph_typer2_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)

      put_registrations([registration("eph2", port, rooms_regex: ".*", receive_ephemeral: false)])

      authed(user.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/typing/#{user.user_id}", %{
        "typing" => true,
        "timeout" => 30_000
      })

      refute wait_for(fn -> ephemeral_requests(port) != [] end, 300)
    end

    test "an AS with no matching namespace at all never gets typing pushes" do
      port = 19_702
      start_supervised!({FakeAppService, port: port})
      FakeAppService.transaction_response(port, 200)

      user = register("eph_typer3_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)

      put_registrations([registration("eph3", port, users_regex: "@unrelated_.*")])

      authed(user.token)
      |> jpu("/_matrix/client/v3/rooms/#{room_id}/typing/#{user.user_id}", %{
        "typing" => true,
        "timeout" => 30_000
      })

      refute wait_for(fn -> ephemeral_requests(port) != [] end, 300)
    end
  end

  describe "m.receipt" do
    test "a public m.read receipt reaches an AS matching only by room namespace" do
      port = 19_710
      start_supervised!({FakeAppService, port: port})
      FakeAppService.transaction_response(port, 200)

      user = register("eph_reader_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)
      event_id = send_event(user.token, room_id, "m.room.message", %{"body" => "hi"})

      put_registrations([registration("eph4", port, rooms_regex: ".*")])

      authed(user.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read/#{event_id}", %{})

      assert wait_for(fn -> ephemeral_of_type(port, "m.receipt") != [] end)
      [ev] = ephemeral_of_type(port, "m.receipt")
      assert get_in(ev, ["content", event_id, "m.read", user.user_id, "ts"])
    end

    test "an m.read.private receipt does NOT reach an AS that only matches by room namespace" do
      port = 19_711
      start_supervised!({FakeAppService, port: port})
      FakeAppService.transaction_response(port, 200)

      user = register("eph_private_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)
      event_id = send_event(user.token, room_id, "m.room.message", %{"body" => "hi"})

      put_registrations([registration("eph5", port, rooms_regex: ".*")])

      authed(user.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read.private/#{event_id}", %{})

      # Give any (wrongly-sent) m.receipt push a real chance to arrive
      # before asserting its absence — a plain sleep, since there's no
      # positive event here to wait_for.
      Process.sleep(300)
      assert ephemeral_of_type(port, "m.receipt") == []
    end

    test "an m.read.private receipt DOES reach an AS that owns the receipt's user" do
      port = 19_712
      start_supervised!({FakeAppService, port: port})
      FakeAppService.transaction_response(port, 200)

      username = "eph_owned_#{System.unique_integer([:positive])}"
      user = register(username)
      room_id = create_room(user.token)
      event_id = send_event(user.token, room_id, "m.room.message", %{"body" => "hi"})

      put_registrations([registration("eph6", port, users_regex: "@#{username}:.*")])

      authed(user.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read.private/#{event_id}", %{})

      assert wait_for(fn -> ephemeral_of_type(port, "m.receipt") != [] end)
      [ev] = ephemeral_of_type(port, "m.receipt")
      assert get_in(ev, ["content", event_id, "m.read.private", user.user_id, "ts"])
    end
  end

  describe "m.presence" do
    test "a presence change reaches an AS that owns the user directly" do
      port = 19_720
      start_supervised!({FakeAppService, port: port})
      FakeAppService.transaction_response(port, 200)

      username = "eph_pres_#{System.unique_integer([:positive])}"
      user = register(username)

      put_registrations([registration("eph7", port, users_regex: "@#{username}:.*")])

      authed(user.token)
      |> jpu("/_matrix/client/v3/presence/#{user.user_id}/status", %{
        "presence" => "unavailable"
      })

      # bump_activity (on this very request, and any earlier authenticated
      # one) can independently fire its own "online" m.presence push before
      # the explicit "unavailable" one under test — wait for the specific
      # state this test cares about rather than the first m.presence at all.
      assert wait_for(fn ->
               Enum.any?(
                 ephemeral_of_type(port, "m.presence"),
                 &(&1["content"]["presence"] == "unavailable")
               )
             end)

      [ev] =
        Enum.filter(
          ephemeral_of_type(port, "m.presence"),
          &(&1["content"]["presence"] == "unavailable")
        )

      assert ev["sender"] == user.user_id
      refute Map.has_key?(ev, "room_id")
    end

    test "a presence change reaches an AS that bridges a room the user is joined to" do
      port = 19_721
      start_supervised!({FakeAppService, port: port})
      FakeAppService.transaction_response(port, 200)

      user = register("eph_pres2_#{System.unique_integer([:positive])}")
      create_room(user.token)

      put_registrations([registration("eph8", port, rooms_regex: ".*")])

      authed(user.token)
      |> jpu("/_matrix/client/v3/presence/#{user.user_id}/status", %{"presence" => "unavailable"})

      assert wait_for(fn ->
               Enum.any?(
                 ephemeral_of_type(port, "m.presence"),
                 &(&1["content"]["presence"] == "unavailable")
               )
             end)
    end

    test "a presence change does not reach an unrelated AS" do
      port = 19_722
      start_supervised!({FakeAppService, port: port})
      FakeAppService.transaction_response(port, 200)

      user = register("eph_pres3_#{System.unique_integer([:positive])}")
      create_room(user.token)

      put_registrations([registration("eph9", port, users_regex: "@totally_unrelated_.*")])

      authed(user.token)
      |> jpu("/_matrix/client/v3/presence/#{user.user_id}/status", %{"presence" => "unavailable"})

      refute wait_for(fn -> ephemeral_requests(port) != [] end, 300)
    end
  end
end
