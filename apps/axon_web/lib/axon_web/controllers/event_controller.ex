defmodule AxonWeb.EventController do
  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  plug(AxonWeb.Plug.RateLimit, [bucket: :send_event, key_by: :user] when action == :send_event)

  import Ecto.Query, only: [from: 2]
  alias AxonCore.{EventStore, Repo}
  alias AxonRoom.RoomProcess

  @max_event_size 65_535

  # PUT /_matrix/client/v3/rooms/:room_id/send/:event_type/:txn_id
  def send_event(
        conn,
        %{"room_id" => room_id, "event_type" => event_type, "txn_id" => txn_id} = params
      ) do
    user_id = conn.assigns.current_user_id
    device_id = conn.assigns.current_device_id

    # Reject non-object JSON bodies (body parsed as non-map → "_json" key set by Plug)
    if Map.has_key?(params, "_json") do
      conn
      |> put_status(400)
      |> json(%{"errcode" => "M_BAD_JSON", "error" => "Request body must be a JSON object"})
    else
      # "ts" (timestamp massaging) is a protocol-level query param, not
      # event content — drop it from content regardless of who sent it.
      # Only honored for an appservice (per spec, ordinary users can't
      # backdate history): everyone else's ?ts= is silently ignored, the
      # same tolerance Synapse gives it, rather than erroring on an
      # otherwise-harmless extra query param.
      content = Map.drop(params, ~w(room_id event_type txn_id ts))
      send_opts = send_event_opts(conn, params["ts"])

      # Reject events exceeding 65535 bytes
      case check_event_size(content) do
        :too_large ->
          conn
          |> put_status(413)
          |> json(%{"errcode" => "M_TOO_LARGE", "error" => "Event too large"})

        :ok ->
          # Idempotency check
          case check_txn_idempotency(user_id, device_id, txn_id) do
            {:already_sent, event_id} ->
              json(conn, %{"event_id" => event_id})

            :new ->
              with {:ok, event_id} <-
                     RoomProcess.send_event(room_id, user_id, event_type, content, send_opts) do
                record_txn(user_id, device_id, txn_id, event_id)
                json(conn, %{"event_id" => event_id})
              end
          end
      end
    end
  end

  defp send_event_opts(%{assigns: %{is_appservice: true}}, ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {ms, ""} -> [origin_server_ts: ms]
      _ -> []
    end
  end

  defp send_event_opts(_conn, _ts), do: []

  # PUT /_matrix/client/v3/rooms/:room_id/state/:event_type
  # PUT /_matrix/client/v3/rooms/:room_id/state/:event_type/:state_key
  def send_state_event(conn, %{"room_id" => room_id, "event_type" => event_type} = params) do
    user_id = conn.assigns.current_user_id
    state_key = params["state_key"] || ""

    # Reject non-object JSON bodies
    if Map.has_key?(params, "_json") do
      conn
      |> put_status(400)
      |> json(%{"errcode" => "M_BAD_JSON", "error" => "Request body must be a JSON object"})
    else
      content = Map.drop(params, ~w(room_id event_type state_key))

      case check_event_size(content) do
        :too_large ->
          conn
          |> put_status(413)
          |> json(%{"errcode" => "M_TOO_LARGE", "error" => "Event too large"})

        :ok ->
          with :ok <- validate_state_event(event_type, content, room_id),
               {:ok, event_id} <-
                 RoomProcess.send_event(room_id, user_id, event_type, content,
                   state_key: state_key
                 ) do
            json(conn, %{"event_id" => event_id})
          end
      end
    end
  end

  defp check_event_size(content) do
    case Jason.encode(content) do
      {:ok, json} when byte_size(json) > @max_event_size -> :too_large
      _ -> :ok
    end
  end

  defp validate_state_event("m.room.canonical_alias", content, room_id) do
    alias_val = content["alias"]
    alt_aliases = content["alt_aliases"] || []

    all_aliases = if(alias_val, do: [alias_val], else: []) ++ alt_aliases

    # First validate format: must start with # and contain :
    invalid_format =
      Enum.find(all_aliases, fn a ->
        not (is_binary(a) and String.starts_with?(a, "#") and String.contains?(a, ":"))
      end)

    if invalid_format do
      {:error, {:invalid_alias_format, invalid_format}}
    else
      bad =
        Enum.find(all_aliases, fn a ->
          case Repo.one(from(a2 in "room_aliases", where: a2.alias == ^a, select: a2.room_id)) do
            ^room_id -> false
            _ -> true
          end
        end)

      if bad do
        {:error, {:bad_canonical_alias, bad}}
      else
        :ok
      end
    end
  end

  defp validate_state_event(_type, _content, _room_id), do: :ok

  # GET /_matrix/client/v3/rooms/:room_id/state
  #
  # Per spec (SPEC-216): a user who has left (or been banned from) the
  # room gets the state *as of when they left* here, not the room's
  # current state — RoomProcess only ever holds the live GenServer view,
  # so a departed member is routed to the point-in-time query instead
  # (same `leave_ordering` computation `event_visible?/2` already uses
  # for GET /event/{id} and /messages).
  def get_state(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.current_user_id

    if member_or_forgotten?(room_id, user_id) do
      conn
      |> put_status(403)
      |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})
    else
      bounds = visibility_bounds(room_id, user_id)

      result =
        case departed_boundary(bounds) do
          nil ->
            RoomProcess.get_state(room_id)

          leave_ordering ->
            {:ok,
             EventStore.get_room_state_at(room_id, leave_ordering)
             |> Enum.map(&EventStore.event_to_map/1)}
        end

      case result do
        {:ok, events} ->
          json(conn, events)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # GET /_matrix/client/v3/rooms/:room_id/state/:event_type/:state_key
  #
  # Same departed-member point-in-time routing as get_state/2 above, for
  # a single state key.
  def get_state_event(conn, %{"room_id" => room_id, "event_type" => event_type} = params) do
    user_id = conn.assigns.current_user_id
    state_key = params["state_key"] || ""
    format = params["format"]

    if member_or_forgotten?(room_id, user_id) do
      conn
      |> put_status(403)
      |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})
    else
      bounds = visibility_bounds(room_id, user_id)

      fetched =
        case departed_boundary(bounds) do
          nil ->
            RoomProcess.get_state_event(room_id, event_type, state_key)

          leave_ordering ->
            case EventStore.get_state_event_at(room_id, event_type, state_key, leave_ordering) do
              {:ok, event} -> EventStore.event_to_map(event)
              {:error, :not_found} -> nil
            end
        end

      case fetched do
        nil ->
          {:error, :not_found}

        event ->
          if format == "event" do
            json(conn, event)
          else
            json(conn, event["content"] || %{})
          end
      end
    end
  end

  # `visibility_bounds/2`'s leave_ordering, but only when it actually
  # applies to this request — a current join/invite (or a user who was
  # never a member, already blocked above by member_or_forgotten?/2)
  # gets nil, meaning "use the live/current-state path".
  defp departed_boundary(%{membership: m, leave_ordering: ord}) when m in ["leave", "ban"],
    do: ord

  defp departed_boundary(_bounds), do: nil

  # Regression guard (finding): get_state/2, get_state_event/2, and
  # get_messages/2 used to have no membership check at all (or, for
  # get_messages, only checked "forgotten" — never "never was a member"),
  # meaning any authenticated user on the server could read a private
  # room's full state/timeline just by knowing its room_id. get_relations/2
  # already had the correct nil-or-forgotten check; this mirrors it.
  defp member_or_forgotten?(room_id, user_id) do
    membership =
      Repo.one(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.user_id == ^user_id,
          select: %{membership: m.membership, forgotten: m.forgotten}
        )
      )

    membership == nil or membership.forgotten
  end

  # GET /_matrix/client/v3/rooms/:room_id/event/:event_id
  def get_event(conn, %{"room_id" => room_id, "event_id" => event_id}) do
    user_id = conn.assigns.current_user_id

    # `get_visible_event/1`, not the shared `get_event/1` — a rejected or
    # soft-failed event (e.g. one whose auth_events transitively reference
    # an already-rejected/unknown event, per RoomProcess's any_rejected?/
    # unknown_ids checks) must 404 for a client the same as if it had never
    # been stored at all. Federation's own GET /event/{id} intentionally
    # keeps using get_event/1 instead, since peer servers walking an
    # auth chain need to see rejected events too.
    with {:ok, event} <- EventStore.get_visible_event(event_id) do
      if event.room_id != room_id do
        {:error, :not_found}
      else
        if can_access_event?(user_id, room_id, event) do
          bundled =
            EventStore.bundle_relations_one(room_id, EventStore.event_to_map(event),
              user_id: user_id
            )

          json(conn, bundled)
        else
          {:error, :not_found}
        end
      end
    end
  end

  defp can_access_event?(user_id, room_id, event) do
    room_id |> visibility_bounds(user_id) |> event_visible?(event)
  end

  @doc """
  Precomputes everything `event_visible?/2` needs to decide access for as
  many events in `room_id` as the caller wants, in one round of queries —
  history_visibility, the user's current membership, and (only ever
  looked up when actually relevant to that visibility setting) their
  join/invite/leave orderings. Splitting the "figure out the rules that
  apply to this (user, room)" step from the "does this one event pass
  them" step is what makes bulk filtering (a `/messages` page, a `/sync`
  room) practical — the alternative is a handful of queries repeated
  per event, an N+1 that's fine for `GET /event/{id}`'s single lookup
  but not for a page of dozens.
  """
  def visibility_bounds(room_id, user_id) do
    history_visibility =
      Repo.one(
        from(s in "current_room_state",
          join: e in "events",
          on: e.event_id == s.event_id,
          where:
            s.room_id == ^room_id and s.type == "m.room.history_visibility" and s.state_key == "",
          select: fragment("?->>'history_visibility'", e.content)
        )
      ) || "shared"

    membership =
      Repo.one(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.user_id == ^user_id,
          select: m.membership
        )
      )

    join_ordering =
      if history_visibility in ["joined", "invited"] or membership in ["leave", "ban"],
        do: get_user_membership_ordering(user_id, room_id, "join")

    invite_ordering =
      if history_visibility == "invited",
        do: get_user_invite_before_join(user_id, room_id, join_ordering)

    leave_ordering =
      if membership in ["leave", "ban"],
        do: get_user_membership_ordering(user_id, room_id, membership)

    %{
      history_visibility: history_visibility,
      membership: membership,
      join_ordering: join_ordering,
      invite_ordering: invite_ordering,
      leave_ordering: leave_ordering
    }
  end

  @doc "Given `visibility_bounds/2`'s output, whether `event` (needs only :stream_ordering) is visible. No DB access."
  def event_visible?(bounds, event) do
    if bounds.history_visibility == "world_readable" do
      true
    else
      case {bounds.history_visibility, bounds.membership} do
        {_, nil} ->
          false

        {"shared", "join"} ->
          true

        {"joined", "join"} ->
          bounds.join_ordering != nil and event.stream_ordering >= bounds.join_ordering

        {"invited", "join"} ->
          effective_ordering = bounds.invite_ordering || bounds.join_ordering
          effective_ordering != nil and event.stream_ordering >= effective_ordering

        {_, m} when m in ["leave", "ban"] ->
          within_membership? =
            bounds.leave_ordering != nil and event.stream_ordering <= bounds.leave_ordering

          within_membership? and
            case bounds.history_visibility do
              "shared" ->
                true

              "joined" ->
                bounds.join_ordering != nil and event.stream_ordering >= bounds.join_ordering

              "invited" ->
                effective_ordering = bounds.invite_ordering || bounds.join_ordering
                effective_ordering != nil and event.stream_ordering >= effective_ordering

              _ ->
                false
            end

        _ ->
          false
      end
    end
  end

  defp get_user_membership_ordering(user_id, room_id, membership) do
    Repo.one(
      from(e in "events",
        where:
          e.room_id == ^room_id and
            e.type == "m.room.member" and
            e.state_key == ^user_id and
            fragment("?->>'membership'", e.content) == ^membership,
        order_by: [desc: e.stream_ordering],
        limit: 1,
        select: e.stream_ordering
      )
    )
  end

  defp get_user_invite_before_join(user_id, room_id, join_ordering) do
    if is_nil(join_ordering),
      do: nil,
      else:
        Repo.one(
          from(e in "events",
            where:
              e.room_id == ^room_id and
                e.type == "m.room.member" and
                e.state_key == ^user_id and
                fragment("?->>'membership'", e.content) == "invite" and
                e.stream_ordering < ^join_ordering,
            order_by: [desc: e.stream_ordering],
            limit: 1,
            select: e.stream_ordering
          )
        )
  end

  # GET /_matrix/client/v3/rooms/:room_id/messages
  def get_messages(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id

    if member_or_forgotten?(room_id, user_id) do
      conn
      |> put_status(403)
      |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})
    else
      from_token = params["from"]
      dir = params["dir"] || "b"
      limit = String.to_integer(params["limit"] || "10")
      filter = decode_filter(params["filter"])

      from_ordering = parse_token(from_token) || EventStore.room_max_stream_ordering(room_id) + 1

      bounds = visibility_bounds(room_id, user_id)

      # EventStore.get_messages/4's dir=b is exclusive of `from_ordering`
      # itself (by design — see event_store_test.exs's `stream_ordering +
      # 1` convention for including a specific event on purpose). A
      # departed member's own leave/ban event is the last thing
      # event_visible?/2 will let them see, and it commonly *is*
      # `from_ordering` verbatim: a `from` token lifted from that same
      # user's own /sync `next_batch` (taken right after leaving) carries
      # exactly their leave event's stream_ordering, since that's the
      # newest event they were ever delivered. Left as-is, the exclusive
      # boundary would silently drop that one legitimate event off a
      # backward page. Nudging the query boundary out by one only ever
      # *admits* it to the raw fetch — event_visible?/2 below still caps
      # everything at `leave_ordering`, so nothing past it can leak in.
      from_ordering =
        case departed_boundary(bounds) do
          leave_ordering
          when dir == "b" and not is_nil(leave_ordering) and
                 from_ordering <= leave_ordering ->
            leave_ordering + 1

          _ ->
            from_ordering
        end

      events =
        EventStore.get_messages(room_id, from_ordering, dir, limit)
        |> Enum.filter(&event_visible?(bounds, &1))
        |> filter_contains_url(filter)

      start_token = if from_token, do: from_token, else: Integer.to_string(from_ordering)

      end_ordering =
        if events == [],
          do: from_ordering,
          else:
            if(dir == "b",
              do: hd(events).stream_ordering,
              else: List.last(events).stream_ordering
            )

      chunk =
        events
        |> Enum.map(&EventStore.event_to_map/1)
        |> then(&EventStore.bundle_relations(room_id, &1, user_id: user_id))

      json(conn, %{
        "start" => start_token,
        "end" => Integer.to_string(end_ordering),
        "chunk" => chunk,
        "state" => lazy_loaded_member_state(room_id, chunk, filter)
      })
    end
  end

  # `contains_url` (a RoomEventFilter field): only events whose content has
  # a "url" key when true, only events without one when false. Filtered
  # after the page is fetched rather than in the query — the query already
  # has to serve two independent orderings/cursors; not folding a third,
  # rarely-used predicate into it keeps that simpler at the cost of a page
  # that can come back smaller than `limit` when this filter is active,
  # same known trade-off as everywhere else in this codebase that filters
  # a fetched page rather than the query behind it.
  defp filter_contains_url(events, %{"contains_url" => wants_url}) when is_boolean(wants_url) do
    Enum.filter(events, fn e -> Map.has_key?(e.content || %{}, "url") == wants_url end)
  end

  defp filter_contains_url(events, _filter), do: events

  # `lazy_load_members` (a RoomEventFilter field, not nested under a full
  # Filter's `room.state` the way `/sync` takes it) asks that member events
  # only be sent for senders actually present in this batch, instead of the
  # room's full membership. `include_redundant_members` (default false) lets
  # a client additionally ask for members it likely already has — axon
  # doesn't track per-client "already seen" state across pagination, so it
  # always returns the (deduplicated) current member event per sender, which
  # satisfies both defaults: some redundancy across pages is spec-legal,
  # never omitting a needed one is what actually matters.
  defp lazy_loaded_member_state(room_id, chunk, filter) do
    case filter do
      %{"lazy_load_members" => true} ->
        chunk
        |> Enum.map(& &1["sender"])
        |> Enum.uniq()
        |> Enum.map(&EventStore.get_state_event(room_id, "m.room.member", &1))
        |> Enum.flat_map(fn
          {:ok, event} -> [EventStore.event_to_map(event)]
          {:error, :not_found} -> []
        end)

      _ ->
        []
    end
  end

  defp decode_filter(nil), do: %{}

  defp decode_filter(filter_param) do
    case Jason.decode(filter_param) do
      {:ok, filter} when is_map(filter) -> filter
      _ -> %{}
    end
  end

  # GET /_matrix/client/v1/rooms/:room_id/timestamp_to_event
  #
  # "Jump to date": given a timestamp, the closest event in the requested
  # direction. Membership-gated even for world-readable rooms — the endpoint
  # reveals when a room was active, which a non-member has no claim to.
  #
  # When this server's own history doesn't reach far enough (a user who
  # joined late has no local events from before the join), falls back to
  # AxonFederation.TimestampToEvent, which asks the room's other resident
  # servers over the federation counterpart of this endpoint and, per spec,
  # backfills whatever event they name before it's handed back here — so a
  # client can immediately paginate /context or /messages around it. That
  # covers the case where the local search finds nothing at all, but a
  # local search can also come back with *something* that isn't actually
  # the right answer: see timestamp_answer/3.
  def timestamp_to_event(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id

    with {:ok, ts} <- parse_timestamp(params["ts"]),
         {:ok, dir} <- parse_direction(params["dir"]) do
      cond do
        member_or_forgotten?(room_id, user_id) ->
          conn
          |> put_status(403)
          |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})

        event = timestamp_answer(room_id, ts, dir) ->
          json(conn, %{
            "event_id" => event.event_id,
            "origin_server_ts" => event.origin_server_ts
          })

        true ->
          conn
          |> put_status(404)
          |> json(%{
            "errcode" => "M_NOT_FOUND",
            "error" => "Unable to find event from #{ts} in direction #{dir}"
          })
      end
    else
      {:error, errcode, message} ->
        conn |> put_status(400) |> json(%{"errcode" => errcode, "error" => message})
    end
  end

  # A local answer isn't accepted unconditionally: `EventStore` only ever
  # searches history this server actually holds, and a server whose own
  # history doesn't reach back (or forward) far enough can satisfy the
  # `>=`/`<=` comparison with an event that merely sits at the edge of what
  # it knows — most commonly its own earliest known event in the room, e.g.
  # a member who joined late, queried for a timestamp from before the join.
  # `EventStore.trustworthy_local_timestamp_answer?/3` is the check for
  # that; an untrustworthy answer is treated the same as no answer at all
  # and federation is asked, but if federation comes back empty too the
  # untrustworthy local answer is still better than a bare 404, so it's
  # used as the last resort.
  defp timestamp_answer(room_id, ts, dir) do
    case EventStore.find_event_by_timestamp(room_id, ts, dir) do
      nil ->
        federation_timestamp_fallback(room_id, ts, dir)

      event ->
        if EventStore.trustworthy_local_timestamp_answer?(room_id, event, dir) do
          event
        else
          federation_timestamp_fallback(room_id, ts, dir) || event
        end
    end
  end

  defp federation_timestamp_fallback(room_id, ts, dir) do
    case AxonFederation.TimestampToEvent.find(room_id, ts, dir) do
      {:ok, result} -> result
      :not_found -> nil
    end
  end

  defp parse_timestamp(nil), do: {:error, "M_MISSING_PARAM", "Missing required parameter: ts"}

  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, "M_INVALID_PARAM", "Query parameter ts must be a non-negative integer"}
    end
  end

  # `dir` defaults to "f" per spec.
  defp parse_direction(nil), do: {:ok, "f"}
  defp parse_direction(dir) when dir in ["f", "b"], do: {:ok, dir}

  defp parse_direction(_),
    do: {:error, "M_INVALID_PARAM", "Query parameter dir must be one of \"f\" or \"b\""}

  # GET /_matrix/client/v3/rooms/:room_id/context/:event_id
  #
  # Previously unimplemented — no route at all, so it 404'd generically.
  # Returns the target event plus a window of surrounding timeline and the
  # room's state, which is what a client uses to render a permalink or a
  # search result in context.
  def get_context(conn, %{"room_id" => room_id, "event_id" => event_id} = params) do
    user_id = conn.assigns.current_user_id

    cond do
      member_or_forgotten?(room_id, user_id) ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})

      true ->
        case EventStore.get_event(event_id) do
          {:ok, %{room_id: ^room_id} = event} ->
            # Spec: `limit` is the total number of events returned either
            # side of the target, so split it between the two directions.
            limit = String.to_integer(params["limit"] || "10")
            half = max(div(limit, 2), 1)

            before_events =
              EventStore.get_messages(room_id, event.stream_ordering, "b", half)

            after_events =
              EventStore.get_messages(room_id, event.stream_ordering, "f", half)

            # get_messages/4 returns "b" newest-first, which is already the
            # reverse-chronological order the spec wants for events_before.
            start_ordering =
              case List.last(before_events) do
                nil -> event.stream_ordering
                e -> e.stream_ordering
              end

            end_ordering =
              case List.last(after_events) do
                nil -> event.stream_ordering
                e -> e.stream_ordering
              end

            json(conn, %{
              "start" => Integer.to_string(start_ordering),
              "end" => Integer.to_string(end_ordering),
              "events_before" => Enum.map(before_events, &EventStore.event_to_map/1),
              "event" => EventStore.event_to_map(event),
              "events_after" => Enum.map(after_events, &EventStore.event_to_map/1),
              "state" =>
                room_id |> EventStore.get_current_state() |> Enum.map(&EventStore.event_to_map/1)
            })

          _ ->
            conn
            |> put_status(404)
            |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Event not found"})
        end
    end
  end

  # GET /_matrix/client/v1/rooms/:room_id/relations/:event_id
  # GET /_matrix/client/v1/rooms/:room_id/relations/:event_id/:rel_type
  # GET /_matrix/client/v1/rooms/:room_id/relations/:event_id/:rel_type/:event_type
  def get_relations(conn, %{"room_id" => room_id, "event_id" => event_id} = params) do
    user_id = conn.assigns.current_user_id

    membership =
      Repo.one(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.user_id == ^user_id,
          select: %{membership: m.membership, forgotten: m.forgotten}
        )
      )

    if membership == nil or membership.forgotten do
      conn
      |> put_status(403)
      |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})
    else
      dir = params["dir"] || "b"
      limit = String.to_integer(params["limit"] || "10")
      from_token = params["from"]
      from_ordering = parse_token(from_token) || EventStore.room_max_stream_ordering(room_id) + 1

      events =
        EventStore.get_relations(
          room_id,
          event_id,
          params["rel_type"],
          params["event_type"],
          from_ordering,
          dir,
          limit
        )

      chunk =
        events
        |> Enum.map(&EventStore.event_to_map/1)
        |> then(&EventStore.bundle_relations(room_id, &1, user_id: user_id))

      next_batch =
        case events do
          [] -> nil
          _ -> List.last(events).stream_ordering |> Integer.to_string()
        end

      resp = %{"chunk" => chunk}
      resp = if next_batch, do: Map.put(resp, "next_batch", next_batch), else: resp
      json(conn, resp)
    end
  end

  # GET /_matrix/client/v1/rooms/:room_id/threads
  #
  # Stable spec endpoint (formerly MSC3856). Thread root events, most
  # recently active first — "active" meaning the latest reply, not the
  # root's own position, per `EventStore.get_thread_roots/3`.
  def get_threads(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id

    cond do
      member_or_forgotten?(room_id, user_id) ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})

      params["include"] not in [nil, "all", "participated"] ->
        conn
        |> put_status(400)
        |> json(%{
          "errcode" => "M_INVALID_PARAM",
          "error" => "Query parameter include must be one of \"all\" or \"participated\""
        })

      true ->
        limit = String.to_integer(params["limit"] || "10")
        from_token = params["from"]

        from_ordering =
          parse_token(from_token) || EventStore.room_max_stream_ordering(room_id) + 1

        participated_user_id = if params["include"] == "participated", do: user_id

        roots_with_activity =
          EventStore.get_thread_roots(room_id, from_ordering, limit,
            participated_user_id: participated_user_id
          )

        chunk =
          roots_with_activity
          |> Enum.map(fn {root, _activity} -> EventStore.event_to_map(root) end)
          |> then(&EventStore.bundle_relations(room_id, &1, user_id: user_id))

        next_batch =
          case roots_with_activity do
            [] -> nil
            _ -> roots_with_activity |> List.last() |> elem(1) |> Integer.to_string()
          end

        resp = %{"chunk" => chunk}
        resp = if next_batch, do: Map.put(resp, "next_batch", next_batch), else: resp
        json(conn, resp)
    end
  end

  # PUT /_matrix/client/v3/rooms/:room_id/redact/:event_id/:txn_id
  def redact(
        conn,
        %{"room_id" => room_id, "event_id" => redacts_event_id, "txn_id" => txn_id} = params
      ) do
    user_id = conn.assigns.current_user_id
    device_id = conn.assigns.current_device_id
    reason = params["reason"]

    content = %{"redacts" => redacts_event_id}
    content = if reason, do: Map.put(content, "reason", reason), else: content

    case check_txn_idempotency(user_id, device_id, txn_id) do
      {:already_sent, event_id} ->
        json(conn, %{"event_id" => event_id})

      :new ->
        with {:ok, event_id} <-
               RoomProcess.send_event(room_id, user_id, "m.room.redaction", content) do
          record_txn(user_id, device_id, txn_id, event_id)
          json(conn, %{"event_id" => event_id})
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp check_txn_idempotency(user_id, device_id, txn_id) do
    import Ecto.Query

    case Repo.one(
           from(t in "client_txns",
             where:
               t.user_id == ^user_id and
                 t.device_id == ^device_id and
                 t.txn_id == ^txn_id,
             select: t.event_id
           )
         ) do
      nil -> :new
      event_id -> {:already_sent, event_id}
    end
  end

  defp record_txn(user_id, device_id, txn_id, event_id) do
    Repo.insert_all(
      "client_txns",
      [
        %{
          user_id: user_id,
          device_id: device_id,
          txn_id: txn_id,
          event_id: event_id,
          inserted_at: DateTime.utc_now(:microsecond)
        }
      ],
      on_conflict: :nothing
    )
  end

  defp parse_token(nil), do: nil

  defp parse_token(t) do
    case Integer.parse(t) do
      {n, _} -> n
      :error -> nil
    end
  end
end
