defmodule AxonWeb.FilterController do
  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  import Ecto.Query
  alias AxonCore.Repo

  def create(conn, %{"user_id" => user_id} = params) do
    requester = conn.assigns.current_user_id

    if requester != user_id do
      conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Forbidden"})
    else
      filter = Map.drop(params, ["user_id"])

      case validate_filter(filter) do
        {:error, msg} ->
          conn |> put_status(400) |> json(%{"errcode" => "M_BAD_JSON", "error" => msg})

        :ok ->
          filter_json = Jason.encode!(filter)
          filter_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

          Repo.insert_all(
            "user_filters",
            [
              %{
                filter_id: filter_id,
                user_id: user_id,
                filter: filter_json,
                inserted_at: DateTime.utc_now(:microsecond),
                updated_at: DateTime.utc_now(:microsecond)
              }
            ],
            on_conflict: :nothing
          )

          json(conn, %{"filter_id" => filter_id})
      end
    end
  end

  defp validate_filter(filter) do
    with :ok <- require_map_or_nil(filter["presence"], "presence"),
         :ok <- require_map_or_nil(filter["account_data"], "account_data"),
         :ok <- require_map_or_nil(filter["room"], "room") do
      room = if is_map(filter["room"]), do: filter["room"], else: %{}

      with :ok <- require_map_or_nil(room["timeline"], "room.timeline"),
           :ok <- require_map_or_nil(room["state"], "room.state"),
           :ok <- require_map_or_nil(room["ephemeral"], "room.ephemeral"),
           :ok <- require_map_or_nil(room["account_data"], "room.account_data") do
        Enum.reduce_while(["timeline", "state", "ephemeral", "account_data"], :ok, fn key, _ ->
          section = room[key]

          if is_nil(section) do
            {:cont, :ok}
          else
            case validate_event_filter(section, "room.#{key}") do
              :ok -> {:cont, :ok}
              err -> {:halt, err}
            end
          end
        end)
      end
    end
  end

  defp validate_event_filter(section, prefix) do
    list_keys = ["rooms", "not_rooms", "senders", "not_senders", "types", "not_types"]

    Enum.reduce_while(list_keys, :ok, fn key, _ ->
      val = section[key]

      if is_nil(val) do
        {:cont, :ok}
      else
        if not is_list(val) do
          {:halt, {:error, "#{prefix}.#{key} must be an array"}}
        else
          result = validate_list_items(val, key, "#{prefix}.#{key}")
          if result == :ok, do: {:cont, :ok}, else: {:halt, result}
        end
      end
    end)
  end

  defp validate_list_items(items, key, prefix) when key in ["types", "not_types"] do
    bad = Enum.find(items, fn i -> not is_binary(i) end)
    if bad, do: {:error, "#{prefix} items must be strings"}, else: :ok
  end

  defp validate_list_items(items, key, prefix) when key in ["rooms", "not_rooms"] do
    bad = Enum.find(items, fn i -> not valid_room_id?(i) end)
    if bad, do: {:error, "#{prefix} items must be valid room IDs"}, else: :ok
  end

  defp validate_list_items(items, key, prefix) when key in ["senders", "not_senders"] do
    bad = Enum.find(items, fn i -> not valid_user_id?(i) end)
    if bad, do: {:error, "#{prefix} items must be valid user IDs"}, else: :ok
  end

  defp validate_list_items(_items, _key, _prefix), do: :ok

  defp require_map_or_nil(nil, _), do: :ok

  defp require_map_or_nil(val, field) when is_map(val) do
    if not is_struct(val), do: :ok, else: {:error, "#{field} must be an object"}
  end

  defp require_map_or_nil(_val, field), do: {:error, "#{field} must be an object"}

  defp valid_room_id?(s) when is_binary(s),
    do: String.starts_with?(s, "!") and String.contains?(s, ":")

  defp valid_room_id?(_), do: false

  defp valid_user_id?(s) when is_binary(s),
    do: String.starts_with?(s, "@") and String.contains?(s, ":")

  defp valid_user_id?(_), do: false

  def get(conn, %{"user_id" => user_id, "filter_id" => filter_id}) do
    requester = conn.assigns.current_user_id

    if requester != user_id do
      conn |> put_status(403) |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Forbidden"})
    else
      case Repo.one(
             from(f in "user_filters",
               where: f.filter_id == ^filter_id and f.user_id == ^user_id,
               select: f.filter
             )
           ) do
        nil -> {:error, :not_found}
        filter_json -> json(conn, Jason.decode!(filter_json))
      end
    end
  end
end
