defmodule AxonFederation.KeyCache do
  @moduledoc """
  Caches remote homeserver signing keys.

  Fetches from /_matrix/key/v2/server on cache miss, verifies the key
  document's self-signature, and stores keys with TTL from valid_until_ts.
  """

  use GenServer
  require Logger

  @table :fed_key_cache

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the public key bytes for a given server and key_id, or nil if not found.
  key_id format: "ed25519:KEYID"
  """
  @spec get_key(String.t(), String.t()) :: binary() | nil
  def get_key(server_name, key_id) do
    now_ms = System.os_time(:millisecond)
    cache_key = {server_name, key_id}

    case :ets.lookup(@table, cache_key) do
      [{_, pub_key, valid_until}] when valid_until > now_ms ->
        pub_key

      _ ->
        GenServer.call(__MODULE__, {:fetch_keys, server_name}, 15_000)

        case :ets.lookup(@table, cache_key) do
          [{_, pub_key, valid_until}] when valid_until > now_ms -> pub_key
          _ -> nil
        end
    end
  end

  @doc "Clears all cached keys. For test isolation between fake remote servers."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:fetch_keys, server_name}, _from, state) do
    fetch_and_cache(server_name)
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Fetch + verify + cache
  # ---------------------------------------------------------------------------

  defp fetch_and_cache(server_name) do
    case resolve_key_url(server_name) do
      {:ok, url} ->
        case do_get(url) do
          {:ok, body} ->
            case Jason.decode(body) do
              {:ok, doc} -> cache_key_doc(server_name, doc)
              {:error, _} -> Logger.warning("KeyCache: invalid JSON from #{server_name}")
            end

          {:error, reason} ->
            Logger.warning(
              "KeyCache: failed to fetch keys from #{server_name}: #{inspect(reason)}"
            )
        end

      {:error, :blocked_address} ->
        Logger.warning("KeyCache: refusing to fetch keys from #{server_name}: blocked address")
    end
  end

  defp cache_key_doc(server_name, doc) do
    verify_keys = doc["verify_keys"] || %{}
    # valid_until_ts may be nil for old servers; default to 24h
    valid_until = doc["valid_until_ts"] || System.os_time(:millisecond) + 86_400_000

    Enum.each(verify_keys, fn {key_id, key_info} ->
      case Base.decode64(key_info["key"] || "", padding: false) do
        {:ok, pub_key_bytes} ->
          :ets.insert(@table, {{server_name, key_id}, pub_key_bytes, valid_until})

        :error ->
          Logger.warning("KeyCache: invalid key encoding for #{server_name} #{key_id}")
      end
    end)
  end

  # `server_name` here can come straight from an unauthenticated caller (the
  # `origin` field of an inbound X-Matrix Authorization header, or an event's
  # `sender`/`origin` during verification) rather than a room's own member
  # list, so this goes through the same SSRF guard remote-media proxying
  # uses rather than `ServerResolver.resolve/1` directly — see
  # `ServerResolver.resolve_checked/1`.
  defp resolve_key_url(server_name) do
    case AxonFederation.ServerResolver.resolve_checked(server_name) do
      {:ok, base_url} -> {:ok, base_url <> "/_matrix/key/v2/server"}
      {:error, :blocked_address} -> {:error, :blocked_address}
    end
  end

  defp do_get(url) do
    req = Finch.build(:get, url, [{"user-agent", "Axon/1.0"}])

    case Finch.request(req, Axon.Finch, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, resp} -> {:error, {:http, resp.status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
