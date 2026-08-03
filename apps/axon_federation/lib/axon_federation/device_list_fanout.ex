defmodule AxonFederation.DeviceListFanout do
  @moduledoc """
  Outbound half of `m.device_list_update` federation — previously entirely
  unimplemented (grep the tree before this file existed: the literal string
  `"m.device_list_update"` appeared nowhere in `lib/`, inbound or outbound).
  Per the Server-Server API, "Servers must send m.device_list_update EDUs
  to all the servers who share a room with a given local user, and must be
  sent whenever that user's device list changes... or [when] that user
  joins a room which contains servers which are not already receiving
  updates for that user's device list."

  Polls `device_list_updates` — the same log
  `AxonWeb.SyncHelpers.get_device_list_changes/3` already reads to build
  local `/sync`'s `device_lists.changed` — for rows belonging to a *local*
  user, and for each one, re-sends that user's *entire current* device
  list to every remote server presently sharing a room with them via
  `AxonFederation.OutboundQueue`.

  Two deliberate simplifications, both safe given how `/keys/query`
  already works in this codebase:

  1. No stream_id/prev_id gap-resync. `AxonWeb.KeyController`'s federation
     `/keys/query` fallback (`fetch_remote_keys/2`) does a live round trip
     to the origin server on every local `/keys/query` call for a remote
     user — key material is never trusted from a cached copy. So an EDU
     dropped or delivered out of order costs nothing beyond the receiving
     server's local `/sync` clients being told to re-query a beat late;
     there's no stale cache to reconcile. `stream_id` is still populated
     (`AxonCore.KeyStore.device_list_stream_id/1`, this user's current
     `device_list_updates` watermark) and `prev_id` left `[]` for spec
     shape compliance, not correctness.

  2. Re-sending on *every* device_list_updates row (not just genuinely-new
     shares) is a superset of the spec requirement, not a violation of it —
     "whenever a user joins a room [with servers not already receiving
     updates]" is satisfied because a join always produces a fresh row for
     the joining user (`AxonCore.EventStore`'s membership-change hook,
     Phase 8), and this fans that row out to *every* currently-shared
     server, the new one included. The cost is redundant EDUs to servers
     that already knew; recipients treat it as the same idempotent
     "something changed, go re-query" signal either way.

  Deliberately poll-based, not `Phoenix.PubSub`-driven:
  `AxonCore.KeyStore.record_device_list_update/1` only broadcasts on a
  per-user topic (`"user:\#{user_id}"`, for waking that one user's own
  long-polling `/sync`) — there's no single topic a startup-time listener
  could subscribe to that covers every user who might ever change. A short
  poll interval keeps propagation latency low without one.

  The scan cursor (`last_id`) lives only in this process's memory and
  starts at 0 on every `init/1` — deliberately, not "the current watermark
  at boot": this `GenServer` restarting (a `one_for_one` supervisor
  restart from a transient crash, not just a fresh application boot) must
  not silently skip whatever row was pending right when it crashed, since
  nothing else remembers "was this one already sent" on its behalf.
  Re-scanning from 0 costs a full-table read on every restart and can
  re-enqueue rows already delivered — both cheap and harmless here: the
  table is a small append-only signal log (not device-list content
  itself), `local_user?/2` immediately drops most of it (every row
  recorded for a *remote* user, e.g. by the inbound EDU handler below),
  and re-sending is the same idempotent "something changed, go re-query"
  signal a recipient already has to tolerate out-of-order or duplicated.
  Durability of a change already noticed, across a crash/restart of *this*
  server, is `AxonFederation.OutboundQueue`'s job, not this module's — by
  the time `OutboundQueue.enqueue/2` returns, the transaction is already
  persisted there.
  """

  use GenServer
  require Logger

  import Ecto.Query, only: [from: 2]

  alias AxonCore.{EventStore, KeyStore, Repo}
  alias AxonCrypto.KeyServer
  alias AxonFederation.OutboundQueue

  @poll_interval_ms 500

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # No DB work here, deliberately — mirrors AxonFederation.OutboundQueue's
    # init/1, which also defers its first query to a scheduled tick rather
    # than doing it during application boot. A `Repo` call at this point can
    # run before anything has checked out a sandboxed connection (in test)
    # or before the DB connection pool has finished starting (in prod);
    # raising here would crash this whole app's *supervisor* start (every
    # sibling, not just this child), not just get this one GenServer
    # restarted the way a crash from `handle_info/2` does. `last_id: 0` is
    # a literal, not a query, so it's safe to set synchronously here — see
    # moduledoc for why 0 (not "current watermark") is the right start
    # point on every init, restart included.
    schedule_poll()
    {:ok, %{last_id: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    # A failed poll must never crash this process. Under the Ecto sandbox
    # every poll from *this* process has no ownership (the checkout belongs
    # to whichever test process is running), so the query raises. Crashing
    # here twice a second exhausts the supervisor's restart intensity and
    # takes down the entire axon_federation application with it — including
    # KeyCache's ETS table, which then fails every unrelated test in the
    # suite with "the table identifier does not refer to an existing ETS
    # table". A skipped poll is harmless: `last_id` is unchanged, so the
    # next tick picks up exactly the same rows.
    new_state =
      try do
        poll(state)
      rescue
        e in [DBConnection.OwnershipError, DBConnection.ConnectionError] ->
          _ = e
          state
      end

    schedule_poll()
    {:noreply, new_state}
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)

  defp poll(state) do
    rows =
      Repo.all(
        from(u in "device_list_updates",
          where: u.id > ^state.last_id,
          order_by: [asc: u.id],
          select: %{id: u.id, user_id: u.user_id}
        )
      )

    case rows do
      [] ->
        state

      rows ->
        local_server = KeyServer.server_name()

        rows
        |> Enum.map(& &1.user_id)
        |> Enum.uniq()
        |> Enum.each(&maybe_fan_out(&1, local_server))

        %{state | last_id: rows |> List.last() |> Map.fetch!(:id)}
    end
  end

  defp maybe_fan_out(user_id, local_server) do
    if local_user?(user_id, local_server) do
      case EventStore.remote_servers_for_user(user_id) do
        [] -> :ok
        remote_servers -> fan_out(user_id, remote_servers)
      end
    end
  end

  # device_list_updates also gets rows for *remote* users, recorded when
  # this server processes an inbound m.device_list_update for them (so
  # local clients sharing a room with that remote user see
  # device_lists.changed) -- never re-broadcast those, only a user's own
  # home server speaks for their device list.
  defp local_user?(user_id, local_server) do
    case String.split(user_id, ":", parts: 2) do
      [_localpart, ^local_server] -> true
      _ -> false
    end
  end

  defp fan_out(user_id, remote_servers) do
    origin = KeyServer.server_name()
    stream_id = KeyStore.device_list_stream_id(user_id)
    display_names = KeyStore.device_display_names(user_id)
    device_ids = KeyStore.device_ids_for_user(user_id)

    Enum.each(device_ids, fn device_id ->
      edu = build_edu(user_id, device_id, Map.get(display_names, device_id), stream_id)

      Enum.each(remote_servers, fn server ->
        OutboundQueue.enqueue(server, %{
          "origin" => origin,
          "origin_server_ts" => System.os_time(:millisecond),
          "pdus" => [],
          "edus" => [edu]
        })
      end)
    end)
  end

  defp build_edu(user_id, device_id, device_display_name, stream_id) do
    %{
      "edu_type" => "m.device_list_update",
      "content" => %{
        "user_id" => user_id,
        "device_id" => device_id,
        "device_display_name" => device_display_name,
        "stream_id" => stream_id,
        "prev_id" => [],
        "deleted" => false
      }
    }
  end
end
