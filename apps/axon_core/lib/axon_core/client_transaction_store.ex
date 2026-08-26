defmodule AxonCore.ClientTransactionStore do
  @moduledoc false

  import Ecto.Query, only: [from: 2]
  alias AxonCore.Repo

  @default_lock_timeout_ms 1_000

  def request_scope(tag, components) when is_binary(tag) and is_list(components) do
    [tag | components]
    |> Enum.map(fn component ->
      component = to_string(component)
      "#{byte_size(component)}:#{component}"
    end)
    |> IO.iodata_to_binary()
  end

  def advisory_key(%{
        user_id: user_id,
        device_id: device_id,
        txn_id: txn_id,
        request_scope: scope
      }) do
    <<key::signed-64, _::binary>> =
      :crypto.hash(:sha256, :erlang.term_to_binary({user_id, device_id, txn_id, scope}))

    key
  end

  def lock(transaction) do
    timeout =
      Application.get_env(
        :axon_core,
        :client_transaction_lock_timeout_ms,
        @default_lock_timeout_ms
      )

    with {:ok, _} <- Repo.query("SELECT set_config('lock_timeout', $1, true)", ["#{timeout}ms"]),
         {:ok, _} <- Repo.query("SELECT pg_advisory_xact_lock($1)", [advisory_key(transaction)]) do
      :ok
    else
      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} ->
        {:error, :transaction_lock_timeout}

      {:error, reason} ->
        {:error, {:transaction_lock_failed, reason}}
    end
  end

  def lookup(%{user_id: user_id, device_id: device_id, txn_id: txn_id, request_scope: scope}) do
    case Repo.one(
           from(t in "client_txns",
             where:
               t.user_id == ^user_id and t.device_id == ^device_id and t.txn_id == ^txn_id and
                 t.request_scope == ^scope,
             select: t.event_id
           )
         ) do
      nil -> :new
      event_id -> {:already_sent, event_id}
    end
  end

  def insert!(transaction, event_id) do
    {1, nil} =
      Repo.insert_all("client_txns", [
        %{
          user_id: transaction.user_id,
          device_id: transaction.device_id,
          txn_id: transaction.txn_id,
          request_scope: transaction.request_scope,
          event_id: event_id,
          inserted_at: DateTime.utc_now(:microsecond)
        }
      ])

    :ok
  end
end
