defmodule AxonWeb.AppService.Manager do
  @moduledoc """
  Application Service registry + event dispatcher.

  Loads AS registrations from a list of JSON files and holds them in a
  public ETS table (readable lock-free from any process — auth plugs and
  controllers consult namespace ownership on the hot request path). Also
  subscribes to `"all_events"` (the same PubSub topic `RoomProcess` fans
  federation out from) and, on every new event, hands matching registrations
  to `AxonWeb.AppService.OutboundQueue` for durable, retried delivery.

  ## Registration files

  `config :axon_web, :appservice_registration_files, [path, ...]` — each
  path is a single JSON object (one registration), mirroring Synapse's
  `app_service_config_files` *list* semantics (one file per bridge, so one
  bridge's config edit can't clobber another's) rather than Phase 4's
  original single-file-holding-a-JSON-array shape. JSON rather than YAML:
  this codebase has no YAML dependency anywhere (config is env-var-driven
  in `config/runtime.exs`, and the only other file-based registration
  format in axon — the `_synapse/admin/v1/register` shared-secret bootstrap
  — has no on-disk file at all), and the spec doesn't mandate a format, so
  introducing a new dependency for this alone isn't worth it. A real
  Synapse-style YAML registration a bridge ships by default needs a
  mechanical reformat to JSON before use here — see ROADMAP.md.

  Expected shape (subset of the spec's fields actually consumed):

      {
        "id": "my-bridge",
        "url": "http://localhost:9000",
        "as_token": "...",
        "hs_token": "...",
        "sender_localpart": "_bridge_bot",
        "rate_limited": false,
        "receive_ephemeral": false,
        "namespaces": {
          "users": [{"exclusive": true, "regex": "@_bridge_.*"}],
          "aliases": [{"exclusive": true, "regex": "#_bridge_.*"}],
          "rooms": []
        }
      }

  A file that's missing a required field, has a namespace entry with an
  unparseable regex, or collides on `id`/`as_token`/`hs_token` with an
  already-loaded registration is rejected (logged, skipped) rather than
  crashing boot — one malformed bridge config shouldn't take the whole
  homeserver down.
  """

  use GenServer
  require Logger

  @table :axon_appservices
  @required_fields ~w(id url as_token hs_token sender_localpart namespaces)
  @namespace_kinds ~w(users aliases rooms)

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "All currently-loaded registrations."
  def list_registrations do
    case :ets.lookup(@table, :registrations) do
      [{:registrations, list}] -> list
      [] -> []
    end
  end

  @doc "Re-reads registration files from config. Synchronous; returns the new list."
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "Verify an as_token (AS -> HS auth). Returns {:ok, registration} or :error."
  def verify_as_token(token) when is_binary(token) do
    find(&(&1["as_token"] == token))
  end

  def verify_as_token(_), do: :error

  @doc "Verify an hs_token (HS -> AS auth, used by the AS to authenticate calls axon makes to it). Returns {:ok, registration} or :error."
  def verify_hs_token(token) when is_binary(token) do
    find(&(&1["hs_token"] == token))
  end

  def verify_hs_token(_), do: :error

  @doc "Look up a registration by its `id`."
  def find_by_id(id) do
    find(&(&1["id"] == id))
  end

  @doc "The full mxid of a registration's own bot/sender user."
  def sender_user_id(registration) do
    "@#{registration["sender_localpart"]}:#{server_name()}"
  end

  @doc """
  The registration that exclusively claims `user_id`, if any (checked
  against its `users` namespace only).
  """
  def exclusive_user_owner(user_id), do: exclusive_owner(:users, user_id)

  @doc """
  The registration that exclusively claims `room_alias`, if any (checked
  against its `aliases` namespace only).
  """
  def exclusive_alias_owner(room_alias), do: exclusive_owner(:aliases, room_alias)

  @doc """
  Whether creating `value` (a user_id or room_alias, per `kind`) should be
  blocked: some registration exclusively claims it and `requesting_registration`
  isn't that registration (`nil` — an ordinary, non-AS request — never is).
  The owning AS itself is exempt from its own exclusive claim.
  """
  def exclusive_conflict?(kind, value, requesting_registration) do
    case exclusive_owner(kind, value) do
      nil ->
        false

      owner ->
        is_nil(requesting_registration) or owner["id"] != requesting_registration["id"]
    end
  end

  @doc "Whether `registration` claims `user_id` in its `users` namespace (exclusive or not)."
  def owns_user?(registration, user_id), do: namespace_match?(registration, :users, user_id)

  @doc "Whether `registration` claims `room_alias` in its `aliases` namespace (exclusive or not)."
  def owns_alias?(registration, room_alias),
    do: namespace_match?(registration, :aliases, room_alias)

  @doc """
  Every registration whose `users` or `rooms` namespace matches this event
  (by sender or room_id) — the audience for event dispatch.
  """
  def matching_registrations(sender, room_id) do
    Enum.filter(list_registrations(), fn reg ->
      namespace_match?(reg, :users, sender) or namespace_match?(reg, :rooms, room_id)
    end)
  end

  @doc """
  Attempts on-demand provisioning of an unknown local user by asking the
  owning AS (any registration whose `users` namespace matches, exclusive or
  not) via `GET /_matrix/app/v1/users/:userId`. Best-effort: returns `:ok`
  if some AS claimed it and answered 200 (caller should re-check for the
  user afterwards — the AS is expected to have called back into `/register`
  by the time it responds), `:not_found` if no AS claims this user or every
  claiming AS declined/errored.
  """
  def maybe_provision_user(user_id) do
    case Enum.find(list_registrations(), &namespace_match?(&1, :users, user_id)) do
      nil -> :not_found
      reg -> query_result(AxonWeb.AppService.Client.query_user(reg, user_id))
    end
  end

  @doc "Same as `maybe_provision_user/1` but for a room alias, via `GET /_matrix/app/v1/rooms/:roomAlias`."
  def maybe_provision_alias(room_alias) do
    case Enum.find(list_registrations(), &namespace_match?(&1, :aliases, room_alias)) do
      nil -> :not_found
      reg -> query_result(AxonWeb.AppService.Client.query_room_alias(reg, room_alias))
    end
  end

  defp query_result({:ok, :found}), do: :ok
  defp query_result(_), do: :not_found

  @doc """
  Pushes an ephemeral (`m.typing`/`m.receipt`/`m.presence`) event to every
  registration that opted in via `receive_ephemeral: true` (default false —
  most bridges don't want this traffic) and whose audience this event
  falls in, per spec's "Pushing ephemeral data" section.

  `room_id` is `nil` for `m.presence` (not room-scoped in the transaction
  body itself); room-scoped kinds (`m.typing`, `m.receipt`) match a
  registration whose `users` namespace covers `subject_user_id` (the typer,
  or the receipt's user) *or* whose `rooms` namespace covers `room_id`.
  `private?: true` (for `m.read.private` receipts only) narrows that to
  *just* the user-namespace match — per spec, "private receipts only for
  matching namespaces" — since a private receipt is meant to stay on the
  owning user's own devices/services, not be broadcast to every AS bridging
  the room the way a public `m.read` receipt is.

  `content` is the event's `content` in Client-Server API shape (e.g. for
  `m.typing`, `%{"user_ids" => [...]}`, matching what `/sync`'s ephemeral
  section would carry — reusing that representation rather than the
  federation EDU's per-change-delta shape, since this is a Client-Server
  API-shaped push, not a federation one. `opts[:sender]`, when given, is
  stamped onto the emitted event as `"sender"` (client-event convention) —
  used for `m.presence`, where `subject_user_id` identifies the audience
  but isn't otherwise present in `content`; `m.typing`/`m.receipt` already
  carry every relevant user_id inside `content` and don't need it.
  """
  def dispatch_ephemeral(edu_type, room_id, subject_user_id, content, opts \\ []) do
    private? = Keyword.get(opts, :private?, false)

    registrations =
      list_registrations()
      |> Enum.filter(&(&1["receive_ephemeral"] == true))
      |> Enum.filter(&ephemeral_audience_match?(&1, room_id, subject_user_id, private?))

    ephemeral_event =
      %{"type" => edu_type, "content" => content}
      |> then(fn e -> if room_id, do: Map.put(e, "room_id", room_id), else: e end)
      |> then(fn e ->
        if sender = opts[:sender], do: Map.put(e, "sender", sender), else: e
      end)

    Enum.each(registrations, fn reg ->
      AxonWeb.AppService.OutboundQueue.enqueue(reg["id"], %{
        "events" => [],
        "ephemeral" => [ephemeral_event]
      })
    end)
  end

  defp ephemeral_audience_match?(reg, _room_id, subject_user_id, true) do
    namespace_match?(reg, :users, subject_user_id)
  end

  defp ephemeral_audience_match?(reg, nil, subject_user_id, false) do
    # m.presence: no room in the payload itself — an AS is interested if
    # the presence-having user is one of its own, or it bridges some room
    # that user is currently joined to.
    namespace_match?(reg, :users, subject_user_id) or shares_claimed_room?(reg, subject_user_id)
  end

  defp ephemeral_audience_match?(reg, room_id, subject_user_id, false) do
    namespace_match?(reg, :users, subject_user_id) or namespace_match?(reg, :rooms, room_id)
  end

  defp shares_claimed_room?(reg, user_id) do
    case Map.get(reg["namespaces"] || %{}, "rooms", []) do
      [] ->
        false

      _room_ns ->
        user_id
        |> AxonCore.EventStore.get_joined_rooms()
        |> Enum.any?(&namespace_match?(reg, :rooms, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    do_reload()
    Phoenix.PubSub.subscribe(Axon.PubSub, "all_events")
    # AxonSync.Presence broadcasts state-transition changes here (consumed
    # for real federation by AxonWeb.FederationFanout) — subscribing here
    # too, rather than adding an axon_web dependency to axon_sync, is how
    # m.presence ephemeral AS push (below) learns about a change without a
    # new cross-app coupling; PubSub happily delivers to every subscriber.
    Phoenix.PubSub.subscribe(Axon.PubSub, "federation:fanout")
    {:ok, %{}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {:reply, do_reload(), state}
  end

  @impl true
  def handle_info({:new_event, room_id, event_map}, state) do
    sender = event_map["sender"] || ""
    event_room_id = event_map["room_id"] || room_id

    case matching_registrations(sender, event_room_id) do
      [] ->
        :ok

      regs ->
        payload = %{"events" => [Map.put(event_map, "room_id", event_room_id)]}
        Enum.each(regs, &AxonWeb.AppService.OutboundQueue.enqueue(&1["id"], payload))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:presence_changed, user_id, presence_map}, state) do
    dispatch_ephemeral("m.presence", nil, user_id, presence_map, sender: user_id)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private: loading
  # ---------------------------------------------------------------------------

  defp do_reload do
    paths = Application.get_env(:axon_web, :appservice_registration_files, [])

    registrations =
      paths
      |> Enum.map(&load_one/1)
      |> Enum.reject(&is_nil/1)
      |> dedupe()

    :ets.insert(@table, {:registrations, registrations})
    Logger.info("AppService.Manager loaded #{length(registrations)} registration(s)")
    registrations
  end

  defp load_one(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{} = reg} <- Jason.decode(contents),
         :ok <- validate(reg) do
      reg
    else
      {:error, :enoent} ->
        Logger.warning("AppService registration file not found: #{path}")
        nil

      {:error, %Jason.DecodeError{} = err} ->
        Logger.warning(
          "AppService registration #{path} is not valid JSON: #{Exception.message(err)}"
        )

        nil

      {:error, reason} ->
        Logger.warning("AppService registration #{path} rejected: #{reason}")
        nil

      {:ok, other} ->
        Logger.warning(
          "AppService registration #{path} must be a JSON object, got: #{inspect(other)}"
        )

        nil
    end
  end

  defp validate(reg) do
    with :ok <- require_fields(reg),
         :ok <- validate_namespaces(reg["namespaces"]) do
      :ok
    end
  end

  defp require_fields(reg) do
    missing = Enum.filter(@required_fields, &(!Map.has_key?(reg, &1)))

    if missing == [],
      do: :ok,
      else: {:error, "missing required field(s): #{Enum.join(missing, ", ")}"}
  end

  defp validate_namespaces(namespaces) when is_map(namespaces) do
    errors =
      for kind <- @namespace_kinds,
          entry <- Map.get(namespaces, kind, []),
          error = validate_namespace_entry(kind, entry),
          not is_nil(error),
          do: error

    if errors == [], do: :ok, else: {:error, Enum.join(errors, "; ")}
  end

  defp validate_namespaces(_), do: {:error, "namespaces must be an object"}

  defp validate_namespace_entry(kind, %{"regex" => regex}) when is_binary(regex) do
    case Regex.compile(regex) do
      {:ok, _} -> nil
      {:error, reason} -> "#{kind} namespace regex #{inspect(regex)} invalid: #{inspect(reason)}"
    end
  end

  defp validate_namespace_entry(kind, other),
    do: "#{kind} namespace entry missing string \"regex\": #{inspect(other)}"

  # Rejects a registration whose id/as_token/hs_token collides with one
  # already accepted (first file wins, later ones are dropped with a
  # warning) — the spec requires these to be unique per AS, and a
  # collision would let one bridge's token double as another's.
  defp dedupe(registrations) do
    {kept, _seen} =
      Enum.reduce(registrations, {[], MapSet.new()}, fn reg, {kept, seen} ->
        keys = [{:id, reg["id"]}, {:as_token, reg["as_token"]}, {:hs_token, reg["hs_token"]}]

        if Enum.any?(keys, &MapSet.member?(seen, &1)) do
          Logger.warning(
            "AppService registration #{reg["id"]} dropped: duplicate id/as_token/hs_token"
          )

          {kept, seen}
        else
          {[reg | kept], Enum.into(keys, seen)}
        end
      end)

    Enum.reverse(kept)
  end

  # ---------------------------------------------------------------------------
  # Private: namespace matching
  # ---------------------------------------------------------------------------

  defp find(pred) do
    case Enum.find(list_registrations(), pred) do
      nil -> :error
      reg -> {:ok, reg}
    end
  end

  defp exclusive_owner(kind, value) do
    Enum.find(list_registrations(), fn reg ->
      Enum.any?(Map.get(reg["namespaces"] || %{}, to_string(kind), []), fn ns ->
        ns["exclusive"] == true and regex_match?(ns["regex"], value)
      end)
    end)
  end

  defp namespace_match?(registration, kind, value) do
    Enum.any?(Map.get(registration["namespaces"] || %{}, to_string(kind), []), fn ns ->
      regex_match?(ns["regex"], value)
    end)
  end

  defp regex_match?(nil, _), do: false

  defp regex_match?(pattern, string) do
    case Regex.compile(pattern) do
      {:ok, re} -> Regex.match?(re, string)
      _ -> false
    end
  end

  defp server_name, do: Application.get_env(:axon_web, :server_name, "localhost")
end
