defmodule AxonPush.Notifications do
  @moduledoc """
  Persists and paginates the `notifications` ledger table — a durable
  record of "this event generated a notify push-rule action for this
  user", written by `AxonPush.Dispatcher` alongside (but independent of)
  actual HTTP push delivery.

  This exists purely to back `GET /_matrix/client/v3/notifications`
  (`AxonWeb.NotificationsController`), which needs real history: actions
  taken, event content, timestamp, paginated. It is deliberately NOT used
  to compute the live `unread_notifications`/`notification_count` badge
  clients see in `/sync` and sliding sync — see
  `AxonWeb.SyncHelpers.unread_counts/2`'s doc for why that stays an
  on-the-fly scan instead. Two consequences of keeping them separate:

    * A push rule the user changes later never rewrites what this ledger
      already recorded for a past event — exactly what a live re-scan
      *would* do (re-evaluating with *current* rules), which is correct
      for a "what's currently unread" badge but wrong for a "what actually
      happened" history feed.
    * This ledger only ever gets a row for a room member who was already
      *joined* at the moment their own room's event was dispatched (see
      `AxonPush.Dispatcher.dispatch_event/2`) — so, notably, a user's own
      invite-into-the-room `m.room.member` event is never in it, even
      though it's still visible in real time through their client's
      `invite` section of `/sync`. The live unread-count scan, by
      contrast, walks a room's timeline since a receipt regardless of what
      the user's membership was at each point, so it does still count
      that invite event once the user has joined and is looking at
      "unread since receipt". This is a narrower, deliberate scope for
      /notifications: a feed of things that happened while you were
      actually here, not a literal reconstruction of the badge number.
  """

  import Ecto.Query, only: [from: 2]
  alias AxonCore.Repo

  @default_limit 20
  @max_limit 100

  @doc """
  Record that `event` (already persisted — its `stream_ordering` is looked
  up by `event_id`) generated a notify action for `user_id` in `room_id`.
  No-ops silently if the event can't be found (shouldn't happen in the
  current call graph, since this only ever runs after the event's own
  insert has already committed).
  """
  def record(user_id, room_id, event, actions) do
    case event_meta(event["event_id"]) do
      nil ->
        :ok

      %{stream_ordering: stream_ordering, origin_server_ts: ts} ->
        now = DateTime.utc_now(:microsecond)

        Repo.insert_all(
          "notifications",
          [
            %{
              user_id: user_id,
              room_id: room_id,
              event_id: event["event_id"],
              sender: event["sender"],
              actions: actions,
              highlight: highlight?(actions),
              stream_ordering: stream_ordering,
              ts: ts || 0,
              inserted_at: now
            }
          ],
          on_conflict: :nothing,
          conflict_target: [:user_id, :event_id]
        )

        :ok
    end
  end

  @doc """
  Paginated, newest-first list of `user_id`'s notifications.

  Options:
    * `:from` — an opaque cursor (the `next_token` from a previous call);
      returns rows strictly older than it.
    * `:limit` — max rows to return (default #{@default_limit}, capped at
      #{@max_limit}).
    * `:only` — `"highlight"` restricts to rows with the highlight tweak
      set; anything else (including nil) returns everything.

  Returns `{rows, next_token}` — `next_token` is `nil` when this page
  reached the end of the user's history. Each row is
  `%{id, room_id, event_id, sender, actions, highlight, stream_ordering, ts}`.
  """
  def list(user_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    query =
      from(n in "notifications",
        where: n.user_id == ^user_id,
        order_by: [desc: n.id],
        select: %{
          id: n.id,
          room_id: n.room_id,
          event_id: n.event_id,
          sender: n.sender,
          actions: n.actions,
          highlight: n.highlight,
          stream_ordering: n.stream_ordering,
          ts: n.ts
        }
      )

    query =
      case opts[:from] do
        nil ->
          query

        from_token ->
          case Integer.parse(from_token) do
            {id, _} -> from(n in query, where: n.id < ^id)
            :error -> query
          end
      end

    query =
      case opts[:only] do
        "highlight" -> from(n in query, where: n.highlight == true)
        _ -> query
      end

    rows = query |> limited(limit + 1) |> Repo.all()

    {page, has_more} =
      if length(rows) > limit, do: {Enum.take(rows, limit), true}, else: {rows, false}

    next_token = if has_more, do: page |> List.last() |> Map.fetch!(:id) |> to_string()

    {page, next_token}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp limited(query, limit), do: from(n in query, limit: ^limit)

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp clamp_limit(_), do: @default_limit

  defp event_meta(event_id) do
    Repo.one(
      from(e in "events",
        where: e.event_id == ^event_id,
        select: %{stream_ordering: e.stream_ordering, origin_server_ts: e.origin_server_ts}
      )
    )
  end

  defp highlight?(actions) do
    Enum.any?(actions, fn
      %{"set_tweak" => "highlight", "value" => value} -> value != false
      %{"set_tweak" => "highlight"} -> true
      _ -> false
    end)
  end
end
