defmodule AxonCrypto.KeyServer do
  @moduledoc """
  GenServer holding the local homeserver's Ed25519 signing keypair.

  On start, loads the keypair from `:axon_crypto, :signing_key_path` if
  configured (config/runtime.exs, prod only — generating and persisting
  one there on first boot if the file doesn't exist yet), or generates a
  fresh in-memory-only one otherwise. Fixes what used to be a hard TODO
  here: with no path configured, every restart minted a brand new signing
  identity, invalidating every cached `/_matrix/key/v2/server` response and
  every signature another server had verified against the old key. An
  unset path (the default in dev/test/CI, where identity persistence
  across restarts doesn't matter) keeps that always-fresh behavior
  unchanged. All event signing goes through this process.
  """

  use GenServer
  require Logger

  defstruct [:server_name, :key_id, :public_key, :private_key, :valid_until_ts]

  @key_expiry_ms 7 * 24 * 60 * 60 * 1000

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns {key_id, public_key_b64, valid_until_ts}"
  def server_key_info do
    GenServer.call(__MODULE__, :server_key_info)
  end

  @doc "Signs a binary payload. Returns {key_id, signature_b64}."
  def sign(payload) when is_binary(payload) do
    GenServer.call(__MODULE__, {:sign, payload})
  end

  @doc "Signs an event map. Returns the event with signatures field populated."
  def sign_event(event) when is_map(event) do
    GenServer.call(__MODULE__, {:sign_event, event})
  end

  @doc "Returns the server name this key belongs to."
  def server_name do
    GenServer.call(__MODULE__, :server_name)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    server_name = Keyword.fetch!(opts, :server_name)
    {key_id, public_key, private_key} = load_or_generate_keypair()
    valid_until_ts = System.os_time(:millisecond) + @key_expiry_ms

    Logger.info("KeyServer started for #{server_name} with key_id #{key_id}")

    state = %__MODULE__{
      server_name: server_name,
      key_id: key_id,
      public_key: public_key,
      private_key: private_key,
      valid_until_ts: valid_until_ts
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:server_key_info, _from, state) do
    public_key_b64 = Base.encode64(state.public_key, padding: false)

    # Build the self-signed key info document. Must match, field-for-field,
    # what AxonWeb.KeyController.server_keys/2 actually serves — the
    # signature covers the canonical JSON of the exact response body (minus
    # "signatures"), so omitting a field here that the controller adds back
    # in (e.g. "old_verify_keys") produces a signature that verifies against
    # a document nobody ever receives, and fails for every real recipient.
    unsigned_doc = %{
      "server_name" => state.server_name,
      "valid_until_ts" => state.valid_until_ts,
      "verify_keys" => %{
        state.key_id => %{"key" => public_key_b64}
      },
      "old_verify_keys" => %{}
    }

    sig_bytes =
      :crypto.sign(
        :eddsa,
        :none,
        AxonCrypto.CanonicalJSON.encode_to_binary(unsigned_doc),
        [state.private_key, :ed25519]
      )

    sig_b64 = Base.encode64(sig_bytes, padding: false)

    info = %{
      server_name: state.server_name,
      key_id: state.key_id,
      public_key_b64: public_key_b64,
      valid_until_ts: state.valid_until_ts,
      signatures: %{
        state.server_name => %{state.key_id => sig_b64}
      }
    }

    {:reply, info, state}
  end

  def handle_call(:server_name, _from, state) do
    {:reply, state.server_name, state}
  end

  def handle_call({:sign, payload}, _from, state) do
    sig_bytes = :crypto.sign(:eddsa, :none, payload, [state.private_key, :ed25519])
    sig_b64 = Base.encode64(sig_bytes, padding: false)
    {:reply, {state.key_id, sig_b64}, state}
  end

  def handle_call({:sign_event, event}, _from, state) do
    signed =
      AxonCrypto.EventHash.sign_event(
        event,
        state.server_name,
        state.key_id,
        state.private_key
      )

    {:reply, signed, state}
  end

  @doc "Generates a new Ed25519 keypair. Returns {key_id, public_key_bytes, private_key_bytes}."
  @spec generate_keypair() :: {String.t(), binary(), binary()}
  def generate_keypair do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = "ed25519:" <> (Base.url_encode64(public_key, padding: false) |> binary_part(0, 6))
    {key_id, public_key, private_key}
  end

  # No path configured (dev/test/CI default): always-fresh, in-memory only —
  # unchanged from before persistence existed.
  defp load_or_generate_keypair do
    case Application.get_env(:axon_crypto, :signing_key_path) do
      nil -> generate_keypair()
      path -> load_or_generate_keypair(path)
    end
  end

  defp load_or_generate_keypair(path) do
    case File.read(path) do
      {:ok, contents} ->
        decode_keypair!(contents)

      {:error, :enoent} ->
        keypair = generate_keypair()
        persist_keypair!(path, keypair)
        keypair
    end
  end

  defp decode_keypair!(contents) do
    %{"key_id" => key_id, "public_key" => pub_b64, "private_key" => priv_b64} =
      Jason.decode!(contents)

    {:ok, public_key} = Base.decode64(pub_b64, padding: false)
    {:ok, private_key} = Base.decode64(priv_b64, padding: false)
    {key_id, public_key, private_key}
  end

  defp persist_keypair!(path, {key_id, public_key, private_key}) do
    doc =
      Jason.encode!(%{
        "key_id" => key_id,
        "public_key" => Base.encode64(public_key, padding: false),
        "private_key" => Base.encode64(private_key, padding: false)
      })

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, doc)
    # Contains the private signing key — readable only by the process owner.
    File.chmod!(path, 0o600)
  end
end
