defmodule AxonCore.KeyStore do
  @moduledoc """
  Shared E2EE key-storage queries used by both the client-facing
  `/keys/*` endpoints and the inbound federation `/user/keys/*` endpoints,
  so the two surfaces (local clients, remote servers) return identical data
  for local users.
  """

  alias AxonCore.Repo
  import Ecto.Query

  @doc "Device keys for a local user, keyed by device_id. Returns %{} if none."
  def device_keys_for_user(user_id) do
    rows =
      Repo.all(
        from(dk in "device_keys",
          where: dk.user_id == ^user_id,
          select: %{
            device_id: dk.device_id,
            keys: dk.keys,
            algorithms: dk.algorithms,
            signatures: dk.signatures
          }
        )
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

  @doc "Cross-signing keys of `key_type` (\"master\" | \"self_signing\" | \"user_signing\") for a set of users."
  def cross_signing_keys(user_ids, key_type) do
    Repo.all(
      from(k in "cross_signing_keys",
        where: k.user_id in ^user_ids and k.key_type == ^key_type,
        select: %{user_id: k.user_id, key_json: k.key_json}
      )
    )
    |> Enum.into(%{}, fn row -> {row.user_id, row.key_json} end)
  end

  # Signatures uploaded via /keys/signatures/upload, grouped by their target.
  # Visibility: a user's signatures on their own keys/devices are public;
  # signatures the requester made on other users' keys are private to them.
  # `viewer_user_id` is nil for callers with no authenticated viewer (e.g.
  # inbound federation key queries) — Ecto forbids comparing a field to a
  # pinned `nil` via `==`, so that case only surfaces self-signatures rather
  # than trying (and crashing) to match a viewer that doesn't exist.
  def cross_signing_signatures(target_user_ids, viewer_user_id) do
    visibility_condition =
      if viewer_user_id do
        dynamic([s], s.signing_user_id == s.target_user_id or s.signing_user_id == ^viewer_user_id)
      else
        dynamic([s], s.signing_user_id == s.target_user_id)
      end

    Repo.all(
      from(s in "cross_signing_signatures",
        where: s.target_user_id in ^target_user_ids,
        where: ^visibility_condition,
        select: %{
          target_user_id: s.target_user_id,
          target_key_id: s.target_key_id,
          signing_user_id: s.signing_user_id,
          signing_key_id: s.signing_key_id,
          signature: s.signature
        }
      )
    )
    |> Enum.group_by(fn s -> {s.target_user_id, s.target_key_id} end)
  end

  # Devices are targeted by device_id; cross-signing keys by their key id
  # (e.g. "ed25519:<base64>"), matching what clients send to /signatures/upload.
  def merge_signatures(key_json, target_user_id, target_key_id, sigs_by_target) do
    case Map.get(sigs_by_target, {target_user_id, target_key_id}) do
      nil ->
        key_json

      rows ->
        merged =
          Enum.reduce(rows, key_json["signatures"] || %{}, fn row, acc ->
            Map.update(
              acc,
              row.signing_user_id,
              %{row.signing_key_id => row.signature},
              &Map.put(&1, row.signing_key_id, row.signature)
            )
          end)

        Map.put(key_json, "signatures", merged)
    end
  end

  def merge_cross_signing_key_signatures(keys_by_user, sigs_by_target) do
    Map.new(keys_by_user, fn {user_id, key_json} ->
      merged =
        (key_json["keys"] || %{})
        |> Map.keys()
        |> Enum.reduce(key_json, fn key_id, acc ->
          merge_signatures(acc, user_id, key_id, sigs_by_target)
        end)

      {user_id, merged}
    end)
  end

  @doc "Atomically claims one unused OTK, falling back to the (non-consumed) fallback key."
  def claim_one_time_key(user_id, device_id, algorithm) do
    result =
      Repo.transaction(fn ->
        row =
          Repo.one(
            from(k in "one_time_keys",
              where:
                k.user_id == ^user_id and
                  k.device_id == ^device_id and
                  k.algorithm == ^algorithm and
                  k.claimed == false,
              limit: 1,
              lock: "FOR UPDATE SKIP LOCKED",
              select: %{id: k.id, key_id: k.key_id, key_json: k.key_json}
            )
          )

        if row do
          Repo.update_all(
            from(k in "one_time_keys", where: k.id == ^row.id),
            set: [claimed: true]
          )

          %{row.key_id => row.key_json}
        else
          case Repo.one(
                 from(fk in "fallback_keys",
                   where:
                     fk.user_id == ^user_id and
                       fk.device_id == ^device_id and
                       fk.algorithm == ^algorithm,
                   select: %{key_id: fk.key_id, key_json: fk.key_json}
                 )
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

  @doc "The device_list_updates.id watermark for a single user (0 if none)."
  def device_list_stream_id(user_id) do
    Repo.one(
      from(u in "device_list_updates",
        where: u.user_id == ^user_id,
        select: max(u.id)
      )
    ) || 0
  end

  @doc "Device display names for a local user, keyed by device_id."
  def device_display_names(user_id) do
    Repo.all(
      from(d in "devices",
        where: d.user_id == ^user_id,
        select: {d.device_id, d.display_name}
      )
    )
    |> Enum.into(%{})
  end

  @doc """
  Fully removes a device: its `devices` row plus everything tied to its
  cryptographic identity (device keys, one-time keys, fallback keys, and any
  to-device messages still queued for it).

  Use this instead of deleting from `devices` alone anywhere a device is
  logged out or explicitly removed (logout, `DELETE /devices/:id`,
  `POST /delete_devices`, dehydrated-device replacement). Without it, the
  device's key material is orphaned and `/keys/query` keeps serving keys for
  a session that no longer exists, indefinitely.
  """
  def purge_device(user_id, device_id) do
    Repo.delete_all(
      from(d in "devices", where: d.user_id == ^user_id and d.device_id == ^device_id)
    )

    Repo.delete_all(
      from(k in "device_keys", where: k.user_id == ^user_id and k.device_id == ^device_id)
    )

    Repo.delete_all(
      from(k in "one_time_keys", where: k.user_id == ^user_id and k.device_id == ^device_id)
    )

    Repo.delete_all(
      from(k in "fallback_keys", where: k.user_id == ^user_id and k.device_id == ^device_id)
    )

    Repo.delete_all(
      from(m in "to_device_messages",
        where: m.target_user_id == ^user_id and m.target_device_id == ^device_id
      )
    )
  end

  @doc "Records that user_id's device/cross-signing keys changed, for /sync device_lists.changed and /keys/changes."
  def record_device_list_update(user_id) do
    # stream_ordering is recorded for informational purposes; queries use id (bigserial).
    ordering = AxonCore.EventStore.current_max_stream_ordering()
    Repo.insert_all("device_list_updates", [%{user_id: user_id, stream_ordering: ordering}])
  end
end
