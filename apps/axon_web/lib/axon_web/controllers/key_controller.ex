defmodule AxonWeb.KeyController do
  use Phoenix.Controller, formats: [:json]

  action_fallback AxonWeb.FallbackController

  alias AxonCrypto.KeyServer
  alias AxonCore.Repo
  import Ecto.Query

  # ---------------------------------------------------------------------------
  # Server keys (federation)
  # GET /_matrix/key/v2/server
  # ---------------------------------------------------------------------------

  def server_keys(conn, _params) do
    info = KeyServer.server_key_info()

    json(conn, %{
      "server_name" => info.server_name,
      "verify_keys" => %{
        info.key_id => %{"key" => info.public_key_b64}
      },
      "old_verify_keys" => %{},
      "signatures" => info.signatures,
      "valid_until_ts" => info.valid_until_ts
    })
  end

  # ---------------------------------------------------------------------------
  # E2EE key endpoints
  # ---------------------------------------------------------------------------

  # POST /_matrix/client/v3/keys/upload
  def upload(conn, params) do
    user_id = conn.assigns.current_user_id
    device_id = conn.assigns.current_device_id

    device_keys = params["device_keys"]
    one_time_keys = params["one_time_keys"] || %{}
    fallback_keys = params["fallback_keys"] || %{}

    # Store device keys
    if device_keys do
      upsert_device_keys(user_id, device_id, device_keys)
    end

    # Store one-time keys — key_id is "algorithm:key_id", e.g. "curve25519:AAAA"
    Enum.each(one_time_keys, fn {key_id, key_json} ->
      algorithm = key_id |> String.split(":", parts: 2) |> hd()

      Repo.insert_all("one_time_keys", [
        %{
          user_id: user_id,
          device_id: device_id,
          algorithm: algorithm,
          key_id: key_id,
          key_json: key_json,
          claimed: false,
          inserted_at: DateTime.utc_now(:microsecond)
        }
      ], on_conflict: :nothing)
    end)

    # Store fallback keys (one per algorithm, keyed by algorithm name)
    Enum.each(fallback_keys, fn {algorithm, key_json} ->
      key_id = "#{algorithm}:fallback"

      Repo.insert_all("fallback_keys", [
        %{
          user_id: user_id,
          device_id: device_id,
          algorithm: algorithm,
          key_id: key_id,
          key_json: key_json,
          used: false
        }
      ], on_conflict: {:replace, [:key_id, :key_json, :used]},
         conflict_target: [:user_id, :device_id, :algorithm])
    end)

    # Count remaining OTKs per algorithm
    counts = count_otks(user_id, device_id)
    json(conn, %{"one_time_key_counts" => counts})
  end

  # POST /_matrix/client/v3/keys/query
  def query(conn, params) do
    device_keys = params["device_keys"] || %{}

    result =
      Enum.into(device_keys, %{}, fn {queried_user_id, _device_ids} ->
        keys = get_device_keys_for_user(queried_user_id)
        {queried_user_id, keys}
      end)

    json(conn, %{"device_keys" => result, "failures" => %{}})
  end

  # POST /_matrix/client/v3/keys/claim
  def claim(conn, params) do
    one_time_keys_request = params["one_time_keys"] || %{}

    result =
      Enum.into(one_time_keys_request, %{}, fn {target_user_id, device_map} ->
        device_result =
          Enum.into(device_map, %{}, fn {target_device_id, algorithm} ->
            key = claim_one_time_key(target_user_id, target_device_id, algorithm)
            {target_device_id, key || %{}}
          end)

        {target_user_id, device_result}
      end)

    json(conn, %{"one_time_keys" => result, "failures" => %{}})
  end

  # GET /_matrix/client/v3/keys/changes
  def changes(conn, _params) do
    # Phase 1 stub — full implementation in Phase 3 (E2EE)
    json(conn, %{"changed" => [], "left" => []})
  end

  # PUT /_matrix/client/v3/sendToDevice/:event_type/:txn_id
  def send_to_device(conn, %{"event_type" => event_type, "txn_id" => _txn_id} = params) do
    sender_id = conn.assigns.current_user_id
    messages = get_in(params, ["messages"]) || %{}

    Enum.each(messages, fn {target_user_id, device_messages} ->
      Enum.each(device_messages, fn {target_device_id, content} ->
        Repo.insert_all("to_device_messages", [
          %{
            sender: sender_id,
            target_user_id: target_user_id,
            target_device_id: target_device_id,
            type: event_type,
            content: content,
            inserted_at: DateTime.utc_now(:microsecond)
          }
        ])
      end)
    end)

    json(conn, %{})
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp upsert_device_keys(user_id, device_id, device_keys) do
    Repo.insert_all("device_keys", [
      %{
        user_id: user_id,
        device_id: device_id,
        keys: device_keys["keys"] || %{},
        algorithms: device_keys["algorithms"] || [],
        signatures: device_keys["signatures"] || %{},
        inserted_at: DateTime.utc_now(:microsecond),
        updated_at: DateTime.utc_now(:microsecond)
      }
    ],
    on_conflict: {:replace, [:keys, :algorithms, :signatures, :updated_at]},
    conflict_target: [:user_id, :device_id])
  end

  defp get_device_keys_for_user(user_id) do
    rows =
      Repo.all(
        from dk in "device_keys",
          where: dk.user_id == ^user_id,
          select: %{
            device_id: dk.device_id,
            keys: dk.keys,
            algorithms: dk.algorithms,
            signatures: dk.signatures
          }
      )

    Enum.into(rows, %{}, fn row ->
      {row.device_id,
       %{
         "algorithms" => row.algorithms,
         "device_id" => row.device_id,
         "keys" => row.keys,
         "signatures" => row.signatures,
         "user_id" => user_id
       }}
    end)
  end

  defp claim_one_time_key(user_id, device_id, algorithm) do
    result =
      Repo.transaction(fn ->
        row =
          Repo.one(
            from k in "one_time_keys",
              where:
                k.user_id == ^user_id and
                  k.device_id == ^device_id and
                  k.algorithm == ^algorithm and
                  k.claimed == false,
              limit: 1,
              lock: "FOR UPDATE SKIP LOCKED",
              select: %{id: k.id, key_id: k.key_id, key_json: k.key_json}
          )

        if row do
          Repo.update_all(
            from(k in "one_time_keys", where: k.id == ^row.id),
            set: [claimed: true]
          )

          %{row.key_id => row.key_json}
        else
          # Fall back to fallback key (not consumed)
          case Repo.one(
                 from fk in "fallback_keys",
                   where:
                     fk.user_id == ^user_id and
                       fk.device_id == ^device_id and
                       fk.algorithm == ^algorithm,
                   select: %{key_id: fk.key_id, key_json: fk.key_json}
               ) do
            nil -> nil
            fk -> %{fk.key_id => fk.key_json}
          end
        end
      end)

    case result do
      {:ok, key} -> key
      _ -> nil
    end
  end

  defp count_otks(user_id, device_id) do
    Repo.all(
      from k in "one_time_keys",
        where: k.user_id == ^user_id and k.device_id == ^device_id and k.claimed == false,
        group_by: k.algorithm,
        select: {k.algorithm, count(k.id)}
    )
    |> Enum.into(%{})
  end
end
