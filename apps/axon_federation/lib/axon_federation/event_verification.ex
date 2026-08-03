defmodule AxonFederation.EventVerification do
  @moduledoc """
  Verifies an inbound PDU's origin signature against its claimed origin
  server's key. Shared between `AxonWeb.FederationController` (PDUs
  arriving over `/send`) and `AxonFederation.Backfill` (PDUs fetched
  proactively via `get_missing_events`/`backfill`) — both need the exact
  same check, since fetched events are not pre-vetted the way a
  `send_join` state snapshot is.
  """

  alias AxonCrypto.EventHash
  alias AxonFederation.KeyCache

  @doc "Verifies `event`'s signature from its claimed origin. Returns :ok or {:error, reason}."
  def verify_signature(event) do
    sender_server = event["sender"] |> to_string() |> AxonCore.MatrixId.server_name()
    origin = event["origin"] || sender_server

    key_id = get_in(event, ["signatures", origin]) |> maybe_first_key()

    if is_nil(key_id) do
      {:error, :missing_signature}
    else
      pub_key = KeyCache.get_key(origin, key_id)

      if is_nil(pub_key) do
        {:error, :key_not_found}
      else
        case EventHash.verify_signature(event, origin, key_id, pub_key) do
          :ok -> :ok
          {:error, _} -> {:error, :bad_signature}
        end
      end
    end
  end

  defp maybe_first_key(nil), do: nil

  defp maybe_first_key(map) when is_map(map) do
    case Map.keys(map) do
      [] -> nil
      [key | _] -> key
    end
  end
end
