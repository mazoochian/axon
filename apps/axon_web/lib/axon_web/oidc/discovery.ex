defmodule AxonWeb.Oidc.Discovery do
  @moduledoc """
  Caches the configured Authorization Server's OAuth 2.0 / OIDC discovery
  document (RFC8414 `.well-known/openid-configuration`), so we don't hit
  the network on every request that needs the introspection/authorization/
  token endpoint URLs.
  """

  use GenServer
  require Logger

  @table :oidc_discovery_cache
  @ttl_ms 3_600_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns `{:ok, metadata_map}` or `{:error, reason}` for the configured issuer."
  @spec metadata(String.t()) :: {:ok, map()} | {:error, term()}
  def metadata(issuer) do
    now_ms = System.os_time(:millisecond)

    case :ets.lookup(@table, issuer) do
      [{_, doc, fetched_at}] when fetched_at + @ttl_ms > now_ms ->
        {:ok, doc}

      _ ->
        GenServer.call(__MODULE__, {:fetch, issuer}, 15_000)
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:fetch, issuer}, _from, state) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"
    req = Finch.build(:get, url, [{"accept", "application/json"}])

    result =
      case Finch.request(req, Axon.Finch, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, doc} ->
              :ets.insert(@table, {issuer, doc, System.os_time(:millisecond)})
              {:ok, doc}

            {:error, _} ->
              {:error, :invalid_json}
          end

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          Logger.warning("OIDC discovery fetch failed for #{issuer}: #{inspect(reason)}")
          {:error, reason}
      end

    {:reply, result, state}
  end
end
