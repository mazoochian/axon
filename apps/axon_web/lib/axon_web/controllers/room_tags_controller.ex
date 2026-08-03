defmodule AxonWeb.RoomTagsController do
  @moduledoc """
  Room tagging — https://spec.matrix.org/v1.18/client-server-api/#room-tagging

  Tags are per-user, per-room organizational labels (`m.favourite`,
  `m.lowpriority`, `m.server_notice`, or any custom namespaced tag) with an
  optional `order` used to sort within a tag. Per spec they are surfaced to
  clients as ordinary room account data of type `m.tag` with shape
  `{"tags": {"<tag>": {"order": <number>}, ...}}` — so this controller is
  a thin read-modify-write layer on top of the SAME `room_account_data`
  table that `AxonWeb.AccountDataController` uses for
  `GET/PUT /user/:user_id/rooms/:room_id/account_data/:type`, keyed by
  `type: "m.tag"`. This is also exactly how `AxonWeb.ServerNotices` already
  writes the `m.server_notice` tag, so PUT/DELETE here read-modify-write
  the same `tags` map rather than clobbering it.
  """

  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  import Ecto.Query
  alias AxonCore.Repo

  @tag_type "m.tag"

  # GET /_matrix/client/v3/user/:user_id/rooms/:room_id/tags
  def index(conn, %{"user_id" => user_id, "room_id" => room_id}) do
    requester = conn.assigns.current_user_id

    if user_id != requester do
      {:error, :forbidden}
    else
      json(conn, %{"tags" => tags_map(user_id, room_id)})
    end
  end

  # PUT /_matrix/client/v3/user/:user_id/rooms/:room_id/tags/:tag
  def put(conn, %{"user_id" => user_id, "room_id" => room_id, "tag" => tag} = params) do
    requester = conn.assigns.current_user_id

    if user_id != requester do
      {:error, :forbidden}
    else
      tag_content = Map.take(params, ["order"])

      user_id
      |> tags_map(room_id)
      |> Map.put(tag, tag_content)
      |> then(&write_tags(user_id, room_id, &1))

      json(conn, %{})
    end
  end

  # DELETE /_matrix/client/v3/user/:user_id/rooms/:room_id/tags/:tag
  def delete(conn, %{"user_id" => user_id, "room_id" => room_id, "tag" => tag}) do
    requester = conn.assigns.current_user_id

    if user_id != requester do
      {:error, :forbidden}
    else
      # Deleting a tag that isn't set is not an error — just a no-op write
      # of the (unchanged) map.
      user_id
      |> tags_map(room_id)
      |> Map.delete(tag)
      |> then(&write_tags(user_id, room_id, &1))

      json(conn, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp tags_map(user_id, room_id) do
    case Repo.one(
           from(a in "room_account_data",
             where: a.user_id == ^user_id and a.room_id == ^room_id and a.type == @tag_type,
             select: a.content
           )
         ) do
      %{"tags" => tags} when is_map(tags) -> tags
      _ -> %{}
    end
  end

  defp write_tags(user_id, room_id, tags) do
    Repo.insert_all(
      "room_account_data",
      [
        %{
          user_id: user_id,
          room_id: room_id,
          type: @tag_type,
          content: %{"tags" => tags}
        }
      ],
      on_conflict: {:replace, [:content]},
      conflict_target: [:user_id, :room_id, :type]
    )

    :ok
  end
end
