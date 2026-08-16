defmodule AxonFederation.Backfill do
  @moduledoc """
  Closes the ancestry gap that opens when an inbound PDU's `prev_events`
  reference events we don't have locally — previously, no code path
  anywhere fetched that missing history from the origin server; the gap
  was silently left unresolved (`AxonRoom.StateResolver` just drops the
  unknown branch from consideration, and a PDU whose ancestry can't be
  resolved either applies against incomplete state or fails auth and gets
  soft-failed, with no attempt to catch up).

  Two-step strategy, per the Server-Server API:
  1. `POST get_missing_events` — for a small/recent gap (the common case:
     we missed one or two live transactions), asks the origin directly for
     the events between what we have and what we're missing.
  2. `GET backfill` — if `get_missing_events` doesn't fully close the gap
     (either it returned nothing, or the fetched events themselves have
     unresolved ancestors), falls back to pulling a batch of history
     before the still-missing point.

  Fetched events are **not** pre-vetted the way a `send_join` state
  snapshot is (see `AxonFederation.RoomJoin`) — each one still goes
  through the same signature verification + `RoomProcess.apply_remote_event`
  auth-check/state-resolution path a live `/send` PDU would, applied
  oldest-first so later events' auth checks see their own prev_events
  already persisted.
  """

  require Logger

  alias AxonCore.EventStore
  alias AxonCrypto.EventHash
  alias AxonFederation.{EventVerification, HttpClient}
  alias AxonRoom.RoomProcess

  @get_missing_events_limit 20
  @backfill_limit 100

  @doc """
  Fetches a single event we don't hold at all (not one referenced as a gap
  by a PDU we already trust — nothing vouches for this one yet), verifies
  its signature, closes whatever ancestry gap *it* has via `catch_up/3`,
  and applies it. Used by `AxonFederation.TimestampToEvent` when a remote
  server's timestamp_to_event answer names an event id we've never seen:
  per the Server-Server API, the requesting server "should try to backfill
  this event" so a client can immediately paginate `/context` or
  `/messages` around it, not just be handed a bare event id.

  Returns `{:ok, event_id}` or `{:error, reason}` — unlike `catch_up/3`
  (which soft-fails silently, matching /send's tolerance for junk from a
  trusted live stream) failure here is reported, since the caller needs to
  know whether the timestamp/event pair it's about to hand back to a
  client actually landed.
  """
  def fetch_and_apply_event(room_id, origin, event_id) do
    path = "/_matrix/federation/v1/event/#{URI.encode(event_id)}"

    room_version = AxonCore.EventStore.get_room_version(room_id)

    with {:ok, %{"pdus" => [pdu | _]}} <- HttpClient.get(origin, path),
         :ok <- EventVerification.verify_signature(pdu, room_version) do
      catch_up(room_id, origin, pdu)
      RoomProcess.apply_remote_event(room_id, pdu)
    else
      {:ok, _} -> {:error, :malformed_event_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Given a PDU about to be applied and the `origin` server it arrived from,
  fetches and applies any of its `prev_events` we don't already have
  locally. A no-op (cheap: one batched local lookup) when there's no gap.
  """
  def catch_up(room_id, origin, pdu) do
    prev_events = pdu["prev_events"] || []

    case missing_ids(prev_events) do
      [] -> :ok
      missing -> close_gap(room_id, origin, pdu, missing)
    end
  end

  defp missing_ids(event_ids) do
    known = EventStore.get_event_maps(event_ids)
    Enum.reject(event_ids, &Map.has_key?(known, &1))
  end

  # `pdu` (not just its missing `prev_events`) has to be threaded through to
  # `fetch_get_missing_events/3` — see that function's doc for why passing
  # the missing prev_event ids themselves as `latest_events` (the bug this
  # replaced) made every well-formed `get_missing_events` request fail.
  defp close_gap(room_id, origin, pdu, missing) do
    case fetch_get_missing_events(room_id, origin, pdu) do
      {:ok, events} when events != [] ->
        apply_oldest_first(room_id, origin, events)

        # get_missing_events can itself return events whose own
        # prev_events are still gaps (a deep catch-up, not just one
        # missed transaction) — fall back to backfill for whatever's
        # still unresolved rather than assuming one round trip suffices.
        case missing_ids(missing) do
          [] -> :ok
          still_missing -> fetch_and_apply_backfill(room_id, origin, still_missing)
        end

      {:ok, []} ->
        # A well-formed response the origin had nothing to add to —
        # distinct from the request itself failing below. Falling back to
        # backfill here anyway was wrong: the origin already told us,
        # successfully, that get_missing_events has nothing more to give;
        # asking again via a completely different endpoint isn't a retry,
        # it's an unprompted extra request no caller expects (Complement:
        # TestOutboundFederationIgnoresMissingEventWithBadJSONForRoomVersion6's
        # fake server only stubs get_missing_events for this exact
        # scenario and fails the test on any other inbound request).
        # Give up on this gap for now — the same "harmless, next event
        # retries" tradeoff as a request that errors out entirely.
        :error

      _ ->
        fetch_and_apply_backfill(room_id, origin, missing)
    end
  end

  defp fetch_and_apply_backfill(room_id, origin, missing) do
    case fetch_backfill(room_id, origin, missing) do
      {:ok, events} when events != [] ->
        apply_oldest_first(room_id, origin, events)

      _ ->
        Logger.warning(
          "AxonFederation.Backfill: could not close ancestry gap for #{room_id} " <>
            "from #{origin} (missing: #{inspect(missing)})"
        )

        :error
    end
  end

  # Per the Server-Server API, `latest_events` is the event(s) whose
  # ancestry the *receiving* server wants walked backwards from — i.e. the
  # PDU we just got that has a gap — and `earliest_events` is the boundary
  # of what we already have, so the response doesn't walk further back
  # than necessary. This previously passed the *missing prev_event ids*
  # as `latest_events` instead of `pdu`'s own id, which asks the origin
  # for the wrong thing entirely (walk back from an event we don't have,
  # rather than from the one we do) and fails a well-formed-request check
  # against any strict server (Complement's `TestGetMissingEventsGapFilling`
  # and `TestCorruptedAuthChain` both assert on this request's shape).
  #
  # `pdu["event_id"]` alone isn't enough, either: room versions 3+ never
  # carry "event_id" on the wire (it's the reference hash), so for any
  # modern room this sent a literal `null` as `latest_events` — a
  # well-formed-looking but content-wrong request no strict server accepts
  # (Complement: TestOutboundFederationEventSizeGetMissingEvents caught
  # this — "got latest_events [null] want [$real_event_id]").
  defp fetch_get_missing_events(room_id, origin, pdu) do
    path = "/_matrix/federation/v1/get_missing_events/#{URI.encode(room_id)}"

    body = %{
      "earliest_events" => known_head_ids(room_id),
      "latest_events" => [pdu_event_id(pdu, room_id)],
      "limit" => @get_missing_events_limit,
      "min_depth" => 0
    }

    case HttpClient.post(origin, path, body) do
      {:ok, %{"events" => events}} when is_list(events) ->
        {:ok, events}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} = err ->
        Logger.warning(
          "get_missing_events to #{origin} for #{room_id} failed: #{inspect(reason)}"
        )

        err
    end
  end

  # event_id as-is when the wire carried one (room v1/v2), otherwise the
  # reference hash room versions 3+ derive it from — same pattern
  # AxonWeb.FederationController.compute_event_id/1 and
  # AxonFederation.RoomJoin use for the same wire-format gap.
  defp pdu_event_id(pdu, room_id) do
    pdu_event_id(pdu, room_id, EventStore.get_room_version(room_id))
  end

  defp pdu_event_id(%{"event_id" => id}, _room_id, _room_version) when is_binary(id), do: id
  defp pdu_event_id(pdu, _room_id, room_version), do: EventHash.reference_hash(pdu, room_version)

  # Our own resident room process's current head, as a single-element
  # `earliest_events` boundary — best-effort: an empty list here just means
  # the origin walks back further than strictly necessary, not a correctness
  # problem (unlike `latest_events`, which must be right for the request to
  # ask for anything sensible at all).
  defp known_head_ids(room_id) do
    case RoomProcess.get_position(room_id) do
      {last_event_id, _depth} when is_binary(last_event_id) -> [last_event_id]
      _ -> []
    end
  end

  defp fetch_backfill(room_id, origin, event_ids) do
    v_query = Enum.map_join(event_ids, "&", &"v=#{URI.encode(&1)}")

    path =
      "/_matrix/federation/v1/backfill/#{URI.encode(room_id)}?#{v_query}&limit=#{@backfill_limit}"

    case HttpClient.get(origin, path) do
      {:ok, %{"pdus" => pdus}} when is_list(pdus) ->
        {:ok, pdus}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} = err ->
        Logger.warning("backfill from #{origin} for #{room_id} failed: #{inspect(reason)}")
        err
    end
  end

  # Applies fetched events depth-ascending so each one's own prev_events
  # are already persisted locally by the time RoomProcess auth-checks it
  # (matters when get_missing_events/backfill return a multi-event chain,
  # not just a single missing event).
  #
  # event_id must be backfilled onto each event *before* uniq_by/1 — same
  # room-versions-3+-omit-it-on-the-wire issue as fetch_get_missing_events/3
  # above, but with a worse failure mode here: every such event in this
  # batch collapses to the same `nil` key, so uniq_by silently drops every
  # one but whichever happened to sort first, rather than just sending one
  # malformed request.
  defp apply_oldest_first(room_id, origin, events) do
    room_version = EventStore.get_room_version(room_id)

    events
    |> Enum.map(&Map.put(&1, "event_id", pdu_event_id(&1, room_id, room_version)))
    |> Enum.uniq_by(& &1["event_id"])
    |> Enum.sort_by(&(&1["depth"] || 0))
    |> Enum.each(&verify_and_apply(room_id, origin, &1))
  end

  defp verify_and_apply(room_id, origin, event) do
    room_version = AxonCore.EventStore.get_room_version(room_id)

    with :ok <- EventVerification.verify_signature(event, room_version),
         {:ok, _event_id} <- RoomProcess.apply_remote_event(room_id, event) do
      :ok
    else
      {:error, reason} ->
        Logger.debug(
          "AxonFederation.Backfill: dropping fetched event #{event["event_id"]} " <>
            "from #{origin}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
