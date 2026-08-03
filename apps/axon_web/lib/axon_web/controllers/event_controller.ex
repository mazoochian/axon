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
      content = Map.drop(params, ~w(room_id event_type txn_id))

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
                     RoomProcess.send_event(room_id, user_id, event_type, content) do
                record_txn(user_id, device_id, txn_id, event_id)
                json(conn, %{"event_id" => event_id})
              end
          end
      end
    end
  end

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
  def get_state(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.current_user_id

    if member_or_forgotten?(room_id, user_id) do
      conn
      |> put_status(403)
      |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})
    else
      case RoomProcess.get_state(room_id) do
        {:ok, events} ->
          json(conn, events)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # GET /_matrix/client/v3/rooms/:room_id/state/:event_type/:state_key
  def get_state_event(conn, %{"room_id" => room_id, "event_type" => event_type} = params) do
    user_id = conn.assigns.current_user_id
    state_key = params["state_key"] || ""
    format = params["format"]

    if member_or_forgotten?(room_id, user_id) do
      conn
      |> put_status(403)
      |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})
    else
      case RoomProcess.get_state_event(room_id, event_type, state_key) do
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

    with {:ok, event} <- EventStore.get_event(event_id) do
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
    # Get history_visibility from current state
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

    if history_visibility == "world_readable" do
      true
    else
      # Check the user's membership
      membership =
        Repo.one(
          from(m in "room_memberships",
            where: m.room_id == ^room_id and m.user_id == ^user_id,
            select: m.membership
          )
        )

      case {history_visibility, membership} do
        {_, nil} ->
          false

        {"shared", "join"} ->
          true

        {"joined", "join"} ->
          # Only allow if event was sent AFTER the user joined
          join_ordering = get_user_membership_ordering(user_id, room_id, "join")
          join_ordering != nil and event.stream_ordering >= join_ordering

        {"invited", "join"} ->
          # Find invite stream_ordering that preceded the current join
          join_ordering = get_user_membership_ordering(user_id, room_id, "join")
          invite_ordering = get_user_invite_before_join(user_id, room_id, join_ordering)
          effective_ordering = invite_ordering || join_ordering
          effective_ordering != nil and event.stream_ordering >= effective_ordering

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

      from_ordering = parse_token(from_token) || EventStore.room_max_stream_ordering(room_id) + 1

      events = EventStore.get_messages(room_id, from_ordering, dir, limit)

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
        "state" => []
      })
    end
  end

  # GET /_matrix/client/v1/rooms/:room_id/timestamp_to_event
  #
  # "Jump to date": given a timestamp, the closest event in the requested
  # direction. Membership-gated even for world-readable rooms — the endpoint
  # reveals when a room was active, which a non-member has no claim to.
  #
  # Known gap: this only searches history this server already holds. The spec
  # also allows asking a remote server over federation when the local search
  # comes up empty (a user who joined late has no local events from before the
  # join), which needs the federation half of this endpoint.
  def timestamp_to_event(conn, %{"room_id" => room_id} = params) do
    user_id = conn.assigns.current_user_id

    with {:ok, ts} <- parse_timestamp(params["ts"]),
         {:ok, dir} <- parse_direction(params["dir"]) do
      cond do
        member_or_forgotten?(room_id, user_id) ->
          conn
          |> put_status(403)
          |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of this room"})

        event = EventStore.find_event_by_timestamp(room_id, ts, dir) ->
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
