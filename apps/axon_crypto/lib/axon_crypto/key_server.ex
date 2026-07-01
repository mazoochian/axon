defmodule AxonCrypto.KeyServer do
  @moduledoc """
  GenServer holding the local homeserver's Ed25519 signing keypair.

  On start it generates (or loads from config) the server's signing key.
  All event signing goes through this process.
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
    {key_id, public_key, private_key} = generate_keypair()
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

    # Build the self-signed key info document
    unsigned_doc = %{
      "server_name" => state.server_name,
      "valid_until_ts" => state.valid_until_ts,
      "verify_keys" => %{
        state.key_id => %{"key" => public_key_b64}
      }
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

  # Generates a new Ed25519 keypair. Returns {key_id, public_key_bytes, private_key_bytes}.
  defp generate_keypair do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = "ed25519:" <> (Base.url_encode64(public_key, padding: false) |> binary_part(0, 6))
    {key_id, public_key, private_key}
  end
end
