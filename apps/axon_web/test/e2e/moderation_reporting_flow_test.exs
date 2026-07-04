defmodule AxonWeb.E2E.ModerationReportingFlowTest do
  @moduledoc """
  End-to-end moderation flow chaining pieces that are each unit-tested
  individually (report, kick, ban, unban, join gating) but never exercised
  together in sequence: report a message -> kick the offender -> the kicked
  user can still rejoin a public room -> escalate to ban -> a banned user is
  rejected on rejoin -> unban -> the unbanned user can rejoin again.
  """

  use AxonWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import AxonWeb.TestHelpers

  alias AxonCore.Repo

  defp members(token, room_id) do
    conn = authed(token) |> get("/_matrix/client/v3/rooms/#{room_id}/joined_members")
    assert conn.status == 200
    decode(conn)["joined"] |> Map.keys()
  end

  test "report -> kick -> rejoin -> ban -> rejoin rejected -> unban -> rejoin" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    charlie = register("charlie_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    assert authed(charlie.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{}) |> Map.get(:status) == 200
    assert charlie.user_id in members(alice.token, room_id)

    offending_event_id = send_event(charlie.token, room_id, "m.room.message", %{"body" => "spammy nonsense"})

    # --- report ---
    report_conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/rooms/#{room_id}/report/#{offending_event_id}", %{"reason" => "spam", "score" => -100})

    assert report_conn.status == 200

    reported =
      Repo.one(
        from(r in "reports",
          where: r.room_id == ^room_id and r.event_id == ^offending_event_id,
          select: r.reporter_id
        )
      )

    assert reported == alice.user_id

    # --- kick (power-level creator acting on a reported user) ---
    kick_conn = authed(alice.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/kick", %{"user_id" => charlie.user_id, "reason" => "spam"})
    assert kick_conn.status == 200
    refute charlie.user_id in members(alice.token, room_id)

    # --- kicked (not banned) user can still rejoin a public room ---
    rejoin_conn = authed(charlie.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    assert rejoin_conn.status == 200
    assert charlie.user_id in members(alice.token, room_id)

    # --- escalate to ban ---
    ban_conn = authed(alice.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/ban", %{"user_id" => charlie.user_id, "reason" => "repeat spam"})
    assert ban_conn.status == 200
    refute charlie.user_id in members(alice.token, room_id)

    # --- a banned user is rejected on rejoin, even though the room is public_chat ---
    banned_rejoin_conn = authed(charlie.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    assert banned_rejoin_conn.status == 403

    # --- unban ---
    unban_conn = authed(alice.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/unban", %{"user_id" => charlie.user_id})
    assert unban_conn.status == 200

    # --- can rejoin again after unban ---
    final_rejoin_conn = authed(charlie.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{})
    assert final_rejoin_conn.status == 200
    assert charlie.user_id in members(alice.token, room_id)
  end

  test "a non-privileged member cannot kick or ban another member" do
    alice = register("alice_#{System.unique_integer([:positive])}")
    bob = register("bob_#{System.unique_integer([:positive])}")
    charlie = register("charlie_#{System.unique_integer([:positive])}")
    room_id = create_room(alice.token, %{"preset" => "public_chat"})

    assert authed(bob.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{}) |> Map.get(:status) == 200
    assert authed(charlie.token) |> jp("/_matrix/client/v3/join/#{room_id}", %{}) |> Map.get(:status) == 200

    kick_conn = authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/kick", %{"user_id" => charlie.user_id})
    assert kick_conn.status == 403
    assert charlie.user_id in members(alice.token, room_id)

    ban_conn = authed(bob.token) |> jp("/_matrix/client/v3/rooms/#{room_id}/ban", %{"user_id" => charlie.user_id})
    assert ban_conn.status == 403
  end
end
