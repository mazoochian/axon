defmodule AxonWeb.AppService.Manager do
  @moduledoc """
  Application Service manager. Loads AS registrations from a JSON config file
  and dispatches events to matching ASes.

  Config: `config :axon_web, :appservice_config_path, "appservices.json"`
  If the file doesn't exist, no ASes are registered.

  Registration format (subset of Synapse's):
    [{
      "id": "bridge",
      "url": "http://localhost:9000",
      "as_token": "...",
      "hs_token": "...",
      "sender_localpart": "_bridge",
      "receive_ephemeral": false,
      "protocols": ["irc"],
      "namespaces": {
        "users": [{"exclusive": false, "regex": "@bridge_.*"}],
        "rooms": [],
        "aliases": []
      }
    }]
  """

  use GenServer
  require Logger

  @table :axon_appservices

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Verify an as_token. Returns {:ok, registration} or :error."
  def verify_as_token(token) do
    result = list_registrations() |> Enum.find(fn r -> r["as_token"] == token end)
    if result, do: {:ok, result}, else: :error
  end

  @doc "Verify an hs_token. Returns {:ok, registration} or :error."
  def verify_hs_token(token) do
    result = list_registrations() |> Enum.find(fn r -> r["hs_token"] == token end)
    if result, do: {:ok, result}, else: :error
  end

  @doc """
  Whether `registration` is allowed to act as `user_id` — either its own
  `sender_localpart` user (always implicitly owned, regardless of
  namespace, per the AS spec) or a user matching one of its registered
  `namespaces.users` regexes (impersonation via `?user_id=`).
  """
  def owns_user?(registration, user_id) do
    sender_user_id = "@#{registration["sender_localpart"]}:#{server_name()}"

    user_id == sender_user_id or
      (get_in(registration, ["namespaces", "users"]) || [])
      |> Enum.any?(fn ns -> regex_match?(ns["regex"], user_id) end)
  end

  defp server_name, do: Application.get_env(:axon_web, :server_name, "localhost")

  # ---------------------------------------------------------------------------
  # Third-party network lookups (AS spec "Third party networks")
  # ---------------------------------------------------------------------------

  @doc """
  Every registration that declares `protocol` in its `protocols` field
  (spec: "The external protocols which the application service provides,
  e.g. IRC").
  """
  def registrations_for_protocol(protocol) do
    Enum.filter(list_registrations(), fn reg ->
      protocols = reg["protocols"]
      is_list(protocols) and protocol in protocols
    end)
  end

  @doc "Every distinct protocol name declared by any registration, for `GET /thirdparty/protocols`."
  def all_protocols do
    list_registrations()
    |> Enum.flat_map(fn reg ->
      case reg["protocols"] do
        protocols when is_list(protocols) -> protocols
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  The registration whose `users` namespace covers `user_id`, if any — used
  for the reverse third-party user lookup (`GET /thirdparty/user?userid=`),
  where there is no `protocol` in the request to pick an AS by, so the AS
  to ask is whoever owns the Matrix side of the identity.
  """
  def registration_owning_user(user_id),
    do: Enum.find(list_registrations(), &namespace_match?(&1, "users", user_id))

  @doc "Same as `registration_owning_user/1` but for `GET /thirdparty/location?alias=`."
  def registration_owning_alias(room_alias),
    do: Enum.find(list_registrations(), &namespace_match?(&1, "aliases", room_alias))

  # ---------------------------------------------------------------------------
  # Ephemeral data push (AS spec "Pushing ephemeral data", MSC2409)
  # ---------------------------------------------------------------------------

  @doc """
  Pushes an ephemeral (`m.typing`/`m.receipt`/`m.presence`) event to every
  registration that opted into ephemeral data and whose audience this event
  falls in, per the AS spec's "Pushing ephemeral data" section. Delivery
  goes through the same `PUT /_matrix/app/v1/transactions/:txnId` path
  regular timeline events already use — a transaction with an empty
  `events` list and a populated `ephemeral` one — rather than a second,
  parallel delivery mechanism.

  Opt-in is `receive_ephemeral: true` in the registration (default false
  per spec — most bridges don't want this traffic). The two MSC2409-era
  spellings Complement's own registration generator still emits
  (`push_ephemeral`, `de.sorunome.msc2409.push_ephemeral`) are accepted as
  equivalent, since `AxonWeb.AppService.RegistrationYaml` reads exactly
  those files and a bridge written against the unstable MSC won't have been
  updated to the stable name.

  `room_id` is `nil` for `m.presence` (not room-scoped in the transaction
  body itself); room-scoped kinds (`m.typing`, `m.receipt`) match a
  registration whose `users` namespace covers `subject_user_id` (the typer,
  or the receipt's user) *or* whose `rooms` namespace covers `room_id` —
  the spec's "registered interest in the room itself, or in a user that is
  in the room". `private?: true` (for `m.read.private` receipts only)
  narrows that to *just* the user-namespace match, since a private receipt
  is meant to stay with the owning user's own devices/services rather than
  be broadcast to every AS bridging the room the way a public `m.read`
  receipt is.

  `content` is the event's `content` in Client-Server API shape (e.g. for
  `m.typing`, `%{"user_ids" => [...]}`, matching what `/sync`'s ephemeral
  section carries) rather than the federation EDU's per-change-delta shape
  — this is a Client-Server-API-shaped push, not a federation one.
  `opts[:sender]`, when given, is stamped onto the emitted event as
  `"sender"`; used for `m.presence`, where `subject_user_id` identifies the
  audience but isn't otherwise present in `content`.
  """
  def dispatch_ephemeral(edu_type, room_id, subject_user_id, content, opts \\ []) do
    private? = Keyword.get(opts, :private?, false)

    case Enum.filter(list_registrations(), &receive_ephemeral?/1) do
      [] ->
        :ok

      candidates ->
        ephemeral_event =
          %{"type" => edu_type, "content" => content}
          |> maybe_put("room_id", room_id)
          |> maybe_put("sender", opts[:sender])

        # Off the caller's request path (a controller shouldn't block a
        # client's response on a bridge's HTTP round-trip), but under
        # Axon.TaskSupervisor rather than a bare Task.start so
        # AxonWeb.ConnCase's own drain-before-checkin can see it — the
        # audience match below reads the DB for the presence case. `guarded`
        # wraps the spawn itself as well as the work, so a task supervisor
        # that's already gone during shutdown can't take down the caller
        # (a controller action, or this module's own GenServer loop).
        guarded(fn ->
          Task.Supervisor.start_child(Axon.TaskSupervisor, fn ->
            guarded(fn ->
              candidates
              |> Enum.filter(&ephemeral_audience_match?(&1, room_id, subject_user_id, private?))
              |> Enum.each(
                &push_transaction(&1, %{"events" => [], "ephemeral" => [ephemeral_event]})
              )
            end)
          end)
        end)

        :ok
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp receive_ephemeral?(reg) do
    reg["receive_ephemeral"] == true or reg["push_ephemeral"] == true or
      reg["de.sorunome.msc2409.push_ephemeral"] == true
  end

  defp ephemeral_audience_match?(reg, _room_id, subject_user_id, true) do
    namespace_match?(reg, "users", subject_user_id)
  end

  defp ephemeral_audience_match?(reg, nil, subject_user_id, false) do
    # m.presence: no room in the payload itself — an AS is interested if the
    # presence-having user is one of its own, or it bridges some room that
    # user is currently joined to.
    namespace_match?(reg, "users", subject_user_id) or
      shares_claimed_room?(reg, subject_user_id)
  end

  defp ephemeral_audience_match?(reg, room_id, subject_user_id, false) do
    namespace_match?(reg, "users", subject_user_id) or namespace_match?(reg, "rooms", room_id)
  end

  # Only ever reached for m.presence, and only for a registration that
  # actually claims some room namespace — otherwise there's nothing a
  # joined-rooms lookup could match and the DB read is pure waste.
  defp shares_claimed_room?(reg, user_id) do
    case get_in(reg, ["namespaces", "rooms"]) || [] do
      [] ->
        false

      _room_ns ->
        user_id
        |> AxonCore.EventStore.get_joined_rooms()
        |> Enum.any?(&namespace_match?(reg, "rooms", &1))
    end
  end

  # Same tradeoff (and same rescue set) as AxonWeb.FederationFanout.guarded/1:
  # this runs off a PubSub message published by long-lived, timer-driven
  # processes independent of any test's lifecycle, so a message arriving in
  # the gap between two tests would otherwise raise DBConnection.OwnershipError
  # out of the joined-rooms read. Dropping one ephemeral push in that window
  # is harmless — it's ephemeral data by definition.
  defp guarded(fun) do
    try do
      fun.()
    rescue
      _ in [DBConnection.OwnershipError, DBConnection.ConnectionError] -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    registrations = load_registrations()
    :ets.insert(@table, {:registrations, registrations})
    # Subscribe to all room events so we can fan-out to ASes without a circular dep
    Phoenix.PubSub.subscribe(Axon.PubSub, "all_events")
    # AxonSync.Presence broadcasts presence state-transitions here (consumed
    # for real federation by AxonWeb.FederationFanout) — subscribing here too,
    # rather than adding an axon_web dependency to axon_sync, is how m.presence
    # AS ephemeral push learns about a change without a new cross-app coupling;
    # PubSub delivers to every subscriber.
    Phoenix.PubSub.subscribe(Axon.PubSub, "federation:fanout")
    Logger.info("AppService.Manager started with #{length(registrations)} registration(s)")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:new_event, room_id, event_map}, state) do
    registrations = list_registrations()

    if registrations != [] do
      Task.start(fn -> do_dispatch(event_map, room_id, registrations) end)
    end

    {:noreply, state}
  end

  def handle_info({:presence_changed, user_id, presence_map}, state) do
    dispatch_ephemeral("m.presence", nil, user_id, presence_map, sender: user_id)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp list_registrations do
    case :ets.lookup(@table, :registrations) do
      [{:registrations, list}] -> list
      [] -> []
    end
  end

  defp load_registrations do
    load_json_registrations() ++ load_yaml_registrations()
  end

  defp load_json_registrations do
    path = Application.get_env(:axon_web, :appservice_config_path, "appservices.json")

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, list} when is_list(list) ->
            Logger.info("Loaded #{length(list)} app service registration(s) from #{path}")
            list

          {:error, reason} ->
            Logger.warning("Failed to parse #{path}: #{inspect(reason)}")
            []
        end

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Failed to read #{path}: #{inspect(reason)}")
        []
    end
  end

  # Complement writes one Synapse-style registration YAML per configured
  # application service into every homeserver container it deploys, at a
  # fixed path (`/complement/appservice/<id>.yaml`) — set via
  # AXON_APPSERVICE_DIR in complement/start.sh. Without this, those files
  # existed in the container but nothing ever read them, so any
  # Complement test registering an appservice via a blueprint silently
  # had no working appservice at all (Complement:
  # TestJoinFederatedRoomFromApplicationServiceBridgeUser and others).
  # Config-driven (not hardcoded to that path) so it's a no-op — not an
  # error — outside a Complement run, same tolerance as the JSON loader
  # above having no file at all.
  defp load_yaml_registrations do
    case Application.get_env(:axon_web, :appservice_dir) do
      nil ->
        []

      dir ->
        dir
        |> Path.join("*.yaml")
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          with {:ok, contents} <- File.read(path),
               {:ok, registration} <- AxonWeb.AppService.RegistrationYaml.parse(contents) do
            Logger.info("Loaded app service registration #{inspect(registration["id"])} from #{path}")
            [registration]
          else
            {:error, reason} ->
              Logger.warning("Failed to load app service registration from #{path}: #{inspect(reason)}")
              []
          end
        end)
    end
  end

  defp do_dispatch(event, room_id, registrations) do
    sender = event["sender"] || ""
    state_key = event["state_key"]
    event_room_id = event["room_id"] || room_id

    Enum.each(registrations, fn reg ->
      if matches_namespace?(reg, sender, event_room_id, state_key) do
        deliver(reg, event, room_id)
      end
    end)
  end

  defp matches_namespace?(reg, sender, room_id, _state_key) do
    namespace_match?(reg, "users", sender) or namespace_match?(reg, "rooms", room_id)
  end

  # `kind` is a namespace key as it appears in the registration file:
  # "users", "rooms" or "aliases".
  defp namespace_match?(reg, kind, value) when is_binary(value) do
    (get_in(reg, ["namespaces", kind]) || [])
    |> Enum.any?(fn ns -> regex_match?(ns["regex"], value) end)
  end

  defp namespace_match?(_reg, _kind, _value), do: false

  defp regex_match?(nil, _), do: false

  defp regex_match?(pattern, string) do
    case Regex.compile(pattern) do
      {:ok, re} -> Regex.match?(re, string)
      _ -> false
    end
  end

  defp deliver(reg, event, room_id) do
    push_transaction(reg, %{
      "events" => [Map.put(event, "room_id", event["room_id"] || room_id)]
    })
  end

  # The one outbound AS transaction path — `PUT /_matrix/app/v1/transactions/:txnId`.
  # Both timeline-event dispatch (above) and ephemeral push
  # (`dispatch_ephemeral/5`) go through here; `payload` is the whole
  # transaction body, so an ephemeral push is just an empty `events` list
  # plus a populated `ephemeral` one.
  defp push_transaction(reg, payload) do
    url = reg["url"]
    hs_token = reg["hs_token"]
    txn_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    body = Jason.encode!(payload)

    req =
      Finch.build(
        :put,
        "#{url}/_matrix/app/v1/transactions/#{txn_id}",
        [{"content-type", "application/json"}, {"authorization", "Bearer #{hs_token}"}],
        body
      )

    case Finch.request(req, Axon.Finch, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status}} ->
        Logger.warning("AppService #{reg["id"]} returned #{status} for txn #{txn_id}")

      {:error, reason} ->
        Logger.warning("AppService #{reg["id"]} delivery failed: #{inspect(reason)}")
    end
  end
end
