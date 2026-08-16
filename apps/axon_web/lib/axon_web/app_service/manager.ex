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
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    registrations = load_registrations()
    :ets.insert(@table, {:registrations, registrations})
    # Subscribe to all room events so we can fan-out to ASes without a circular dep
    Phoenix.PubSub.subscribe(Axon.PubSub, "all_events")
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
    user_ns = get_in(reg, ["namespaces", "users"]) || []
    room_ns = get_in(reg, ["namespaces", "rooms"]) || []

    user_match = Enum.any?(user_ns, fn ns -> regex_match?(ns["regex"], sender) end)
    room_match = Enum.any?(room_ns, fn ns -> regex_match?(ns["regex"], room_id) end)

    user_match or room_match
  end

  defp regex_match?(nil, _), do: false

  defp regex_match?(pattern, string) do
    case Regex.compile(pattern) do
      {:ok, re} -> Regex.match?(re, string)
      _ -> false
    end
  end

  defp deliver(reg, event, room_id) do
    url = reg["url"]
    hs_token = reg["hs_token"]
    txn_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

    body =
      Jason.encode!(%{
        "events" => [Map.put(event, "room_id", event["room_id"] || room_id)]
      })

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
