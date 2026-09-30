defmodule AxonWeb.Devices do
  @moduledoc "Removal of a user's devices together with everything tied to them."

  import Ecto.Query
  alias AxonCore.{KeyStore, Repo}
  alias AxonCore.Schema.{AccessToken, RefreshToken}

  def remove(user_id, device_ids) when is_list(device_ids) do
    Repo.update_all(
      from(t in AccessToken, where: t.user_id == ^user_id and t.device_id in ^device_ids),
      set: [valid: false]
    )

    Repo.delete_all(
      from(r in RefreshToken, where: r.user_id == ^user_id and r.device_id in ^device_ids)
    )

    delete_pushers(user_id, device_ids)

    # Purges device_keys/one_time_keys/fallback_keys too, not just the
    # `devices` row, so a removed device's keys stop being served.
    Enum.each(device_ids, &KeyStore.purge_device(user_id, &1))
    KeyStore.record_device_list_update(user_id)
  end

  def delete_pushers(user_id, device_ids) when is_list(device_ids) do
    Repo.delete_all(
      from(p in "pushers", where: p.user_id == ^user_id and p.device_id in ^device_ids)
    )
  end

  @doc "Deletes all of `user_id`'s pushers except those of `keep_device_id` (nil keeps none)."
  def delete_pushers_except(user_id, keep_device_id) do
    q = from(p in "pushers", where: p.user_id == ^user_id)
    q = if keep_device_id, do: from(p in q, where: p.device_id != ^keep_device_id), else: q
    Repo.delete_all(q)
  end
end
