defmodule AxonSync.TypingTest do
  @moduledoc """
  Direct unit tests for `AxonSync.Typing` — previously entirely untested
  despite being the backing store for `/rooms/:room_id/typing/:user_id`.
  ETS-backed and auto-expiring (mirrors `AxonSync.Presence`'s pattern), so
  expiry is exercised the same way: writing an already-expired entry
  directly, then forcing the periodic `:tick` sweep rather than waiting out
  real time.
  """

  use ExUnit.Case, async: false

  alias AxonSync.Typing

  @table :axon_typing

  defp room, do: "!typing_#{System.unique_integer([:positive])}:localhost"
  defp user, do: "@typer_#{System.unique_integer([:positive])}:localhost"

  test "start marks a user as typing, reflected in typing_user_ids" do
    r = room()
    u = user()

    :ok = Typing.start(r, u, 30_000)

    assert u in Typing.typing_user_ids(r)
  end

  test "typing_user_ids only returns users typing in that specific room" do
    r1 = room()
    r2 = room()
    u = user()

    :ok = Typing.start(r1, u, 30_000)

    assert u in Typing.typing_user_ids(r1)
    refute u in Typing.typing_user_ids(r2)
  end

  test "stop removes a typing user immediately" do
    r = room()
    u = user()

    :ok = Typing.start(r, u, 30_000)
    assert u in Typing.typing_user_ids(r)

    :ok = Typing.stop(r, u)
    refute u in Typing.typing_user_ids(r)
  end

  test "stop on a user who was never typing is a no-op" do
    assert Typing.stop(room(), user()) == :ok
  end

  test "an entry whose expiry has already passed is excluded from typing_user_ids" do
    r = room()
    u = user()
    already_expired = System.system_time(:millisecond) - 1_000

    :ets.insert(@table, {{r, u}, already_expired})

    refute u in Typing.typing_user_ids(r)
  end

  test "the tick sweep removes expired entries from the table entirely" do
    r = room()
    u = user()
    already_expired = System.system_time(:millisecond) - 1_000

    :ets.insert(@table, {{r, u}, already_expired})
    assert :ets.member(@table, {r, u})

    send(AxonSync.Typing, :tick)
    :sys.get_state(AxonSync.Typing)

    refute :ets.member(@table, {r, u})
  end

  test "a requested timeout beyond the max is capped, not honored as-is" do
    r = room()
    u = user()

    :ok = Typing.start(r, u, :timer.hours(1))

    [{{^r, ^u}, expires_at}] = :ets.lookup(@table, {r, u})
    max_allowed = System.system_time(:millisecond) + :timer.seconds(121)

    assert expires_at < max_allowed
  end
end
