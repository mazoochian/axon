defmodule AxonWeb.AppService.EphemeralPushTest do
  @moduledoc """
  Regression coverage for Application Service ephemeral data push (the AS
  spec's "Pushing ephemeral data", formerly MSC2409): `m.typing`,
  `m.receipt` (public and private) and `m.presence` reaching a registration
  that opted in via `receive_ephemeral: true`, dispatched through
  `AxonWeb.AppService.Manager.dispatch_ephemeral/5` and delivered over the
  same `PUT /_matrix/app/v1/transactions/:txnId` path timeline events
  already use — a transaction with an empty `events` list and a populated
  `ephemeral` one.

  Each test does its room/user setup *before* registering the fixture AS,
  then registers it immediately ahead of the one action under test. The
  `rooms: [".*"]` fixtures (used to exercise room-namespace matching
  without depending on an unpredictable server-generated room_id) would
  otherwise also match every setup-step timeline event — `m.room.create`,
  membership, power levels — each becoming its own delivery attempt and
  needless noise in the request log.

  Assertions always filter by ephemeral `type` (and, for presence, by the
  specific state): every authenticated request bumps the caller's presence,
  which independently fires its own `m.presence` push whenever an AS's
  namespace happens to cover the user or one of their rooms, so the
  transaction log is never guaranteed to hold exactly one entry.
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
    base = %{
      "id" => id,
      "url" => "http://127.0.0.1:#{port}",
      "as_token" => "as-token-#{id}",
      "hs_token" => "hs-token-#{id}",
      "sender_localpart" => "_#{id}_bot",
      "namespaces" => %{
        "users" => ns(Keyword.get(opts, :users_regex)),
        "aliases" => [],
        "rooms" => ns(Keyword.get(opts, :rooms_regex))
      }
    }

    case Keyword.get(opts, :opt_in, "receive_ephemeral") do
      nil -> base
      key -> Map.put(base, key, true)
    end
  end

  defp ns(nil), do: []
  defp ns(regex), do: [%{"regex" => regex, "exclusive" => false}]

  defp wait_for(fun, timeout_ms \\ 2_000) do
    do_wait_for(fun, System.monotonic_time(:millisecond) + timeout_ms)
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

  defp ephemeral_requests(port) do
    FakeAppService.requests(port)
    |> Enum.filter(&String.starts_with?(&1.path, "/_matrix/app/v1/transactions/"))
    |> Enum.flat_map(&(&1.body["ephemeral"] || []))
  end

  defp ephemeral_of_type(port, type),
    do: Enum.filter(ephemeral_requests(port), &(&1["type"] == type))

  defp start_as(port) do
    start_supervised!({FakeAppService, port: port})
    FakeAppService.transaction_response(port, 200)
    port
  end

  defp type_in(token, room_id, user_id) do
    authed(token)
    |> jpu("/_matrix/client/v3/rooms/#{room_id}/typing/#{user_id}", %{
      "typing" => true,
      "timeout" => 30_000
    })
  end

  describe "m.typing" do
    test "an opted-in AS with a matching rooms namespace gets typing pushes" do
      port = start_as(19_850)

      user = register("eph_typer_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)

      put_registrations([registration("eph1", port, rooms_regex: ".*")])
      type_in(user.token, room_id, user.user_id)

      assert wait_for(fn -> ephemeral_of_type(port, "m.typing") != [] end)
      [ev] = ephemeral_of_type(port, "m.typing")
      assert ev["room_id"] == room_id
      assert ev["content"]["user_ids"] == [user.user_id]
    end

    test "the transaction carries an empty events list alongside the ephemeral one" do
      port = start_as(19_851)

      user = register("eph_txn_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)

      put_registrations([registration("eph2", port, rooms_regex: ".*")])
      type_in(user.token, room_id, user.user_id)

      assert wait_for(fn -> ephemeral_of_type(port, "m.typing") != [] end)

      txn =
        FakeAppService.requests(port)
        |> Enum.find(&(&1.body["ephemeral"] not in [nil, []]))

      assert txn.method == "PUT"
      assert txn.body["events"] == []
      assert {"authorization", "Bearer hs-token-eph2"} in txn.headers
    end

    test "an AS without the opt-in never gets typing pushes, matching namespace or not" do
      port = start_as(19_852)

      user = register("eph_typer2_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)

      put_registrations([registration("eph3", port, rooms_regex: ".*", opt_in: nil)])
      type_in(user.token, room_id, user.user_id)

      refute wait_for(fn -> ephemeral_requests(port) != [] end, 300)
    end

    test "an AS whose namespaces match nothing here never gets typing pushes" do
      port = start_as(19_853)

      user = register("eph_typer3_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)

      put_registrations([registration("eph4", port, users_regex: "@unrelated_.*")])
      type_in(user.token, room_id, user.user_id)

      refute wait_for(fn -> ephemeral_requests(port) != [] end, 300)
    end

    test "the legacy MSC2409 opt-in spelling Complement's registrations use is honored" do
      port = start_as(19_854)

      user = register("eph_msc_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)

      put_registrations([
        registration("eph5", port,
          rooms_regex: ".*",
          opt_in: "de.sorunome.msc2409.push_ephemeral"
        )
      ])

      type_in(user.token, room_id, user.user_id)

      assert wait_for(fn -> ephemeral_of_type(port, "m.typing") != [] end)
    end

    test "the bare push_ephemeral spelling is honored too" do
      port = start_as(19_855)

      user = register("eph_push_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)

      put_registrations([registration("eph6", port, rooms_regex: ".*", opt_in: "push_ephemeral")])
      type_in(user.token, room_id, user.user_id)

      assert wait_for(fn -> ephemeral_of_type(port, "m.typing") != [] end)
    end
  end

  describe "m.receipt" do
    test "a public m.read receipt reaches an AS matching only by room namespace" do
      port = start_as(19_856)

      user = register("eph_reader_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)
      event_id = send_event(user.token, room_id, "m.room.message", %{"body" => "hi"})

      put_registrations([registration("eph7", port, rooms_regex: ".*")])

      authed(user.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read/#{event_id}", %{})

      assert wait_for(fn -> ephemeral_of_type(port, "m.receipt") != [] end)
      [ev] = ephemeral_of_type(port, "m.receipt")
      assert ev["room_id"] == room_id
      assert get_in(ev, ["content", event_id, "m.read", user.user_id, "ts"])
    end

    test "an m.read.private receipt does NOT reach an AS that only matches by room" do
      port = start_as(19_857)

      user = register("eph_private_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)
      event_id = send_event(user.token, room_id, "m.room.message", %{"body" => "hi"})

      put_registrations([registration("eph8", port, rooms_regex: ".*")])

      authed(user.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read.private/#{event_id}", %{})

      # No positive event to wait on, so give a (wrongly-sent) push a real
      # chance to arrive before asserting its absence.
      Process.sleep(300)
      assert ephemeral_of_type(port, "m.receipt") == []
    end

    test "an m.read.private receipt DOES reach an AS that owns the receipt's user" do
      port = start_as(19_858)

      username = "eph_owned_#{System.unique_integer([:positive])}"
      user = register(username)
      room_id = create_room(user.token)
      event_id = send_event(user.token, room_id, "m.room.message", %{"body" => "hi"})

      put_registrations([registration("eph9", port, users_regex: "@#{username}:.*")])

      authed(user.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.read.private/#{event_id}", %{})

      assert wait_for(fn -> ephemeral_of_type(port, "m.receipt") != [] end)
      [ev] = ephemeral_of_type(port, "m.receipt")
      assert get_in(ev, ["content", event_id, "m.read.private", user.user_id, "ts"])
    end

    test "a receipt type that is neither m.read nor m.read.private is not pushed" do
      port = start_as(19_859)

      user = register("eph_other_#{System.unique_integer([:positive])}")
      room_id = create_room(user.token)
      event_id = send_event(user.token, room_id, "m.room.message", %{"body" => "hi"})

      put_registrations([registration("eph10", port, rooms_regex: ".*")])

      authed(user.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/receipt/m.fully_read/#{event_id}", %{})

      Process.sleep(300)
      assert ephemeral_of_type(port, "m.receipt") == []
    end
  end

  describe "m.presence" do
    test "a presence change reaches an AS that owns the user directly" do
      port = start_as(19_860)

      username = "eph_pres_#{System.unique_integer([:positive])}"
      user = register(username)

      put_registrations([registration("eph11", port, users_regex: "@#{username}:.*")])

      authed(user.token)
      |> jpu("/_matrix/client/v3/presence/#{user.user_id}/status", %{"presence" => "unavailable"})

      assert wait_for(fn -> unavailable_presence(port) != [] end)

      [ev | _] = unavailable_presence(port)
      assert ev["sender"] == user.user_id
      # m.presence isn't room-scoped in the transaction body.
      refute Map.has_key?(ev, "room_id")
    end

    test "a presence change reaches an AS that bridges a room the user is joined to" do
      port = start_as(19_861)

      user = register("eph_pres2_#{System.unique_integer([:positive])}")
      create_room(user.token)

      put_registrations([registration("eph12", port, rooms_regex: ".*")])

      authed(user.token)
      |> jpu("/_matrix/client/v3/presence/#{user.user_id}/status", %{"presence" => "unavailable"})

      assert wait_for(fn -> unavailable_presence(port) != [] end)
    end

    test "a presence change does not reach an unrelated AS" do
      port = start_as(19_862)

      user = register("eph_pres3_#{System.unique_integer([:positive])}")
      create_room(user.token)

      put_registrations([registration("eph13", port, users_regex: "@totally_unrelated_.*")])

      authed(user.token)
      |> jpu("/_matrix/client/v3/presence/#{user.user_id}/status", %{"presence" => "unavailable"})

      refute wait_for(fn -> ephemeral_requests(port) != [] end, 300)
    end
  end

  # bump_activity (on this very request, and any earlier authenticated one)
  # can fire its own "online" m.presence push before the explicit
  # "unavailable" one under test — always match on the state, not on "the
  # first m.presence that shows up".
  defp unavailable_presence(port) do
    Enum.filter(ephemeral_of_type(port, "m.presence"), &(&1["content"]["presence"] == "unavailable"))
  end
end
