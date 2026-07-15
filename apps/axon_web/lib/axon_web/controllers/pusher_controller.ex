defmodule AxonWeb.PusherController do
  use Phoenix.Controller, formats: [:json]

  import Ecto.Query
  alias AxonCore.Repo

  # GET /_matrix/client/v3/pushers
  def index(conn, _params) do
    user_id = conn.assigns.current_user_id

    pushers =
      Repo.all(
        from(p in "pushers",
          where: p.user_id == ^user_id,
          select: %{
            kind: p.kind,
            app_id: p.app_id,
            app_display_name: p.app_display_name,
            device_display_name: p.device_display_name,
            pushkey: p.pushkey,
            lang: p.lang,
            data: p.data,
            enabled: p.enabled
          }
        )
      )
      |> Enum.map(fn p ->
        %{
          "kind" => p.kind,
          "app_id" => p.app_id,
          "app_display_name" => p.app_display_name,
          "device_display_name" => p.device_display_name,
          "pushkey" => p.pushkey,
          "lang" => p.lang,
          "data" => p.data,
          "enabled" => p.enabled
        }
      end)

    json(conn, %{"pushers" => pushers})
  end

  # POST /_matrix/client/v3/pushers/set
  def set(conn, params) do
    user_id = conn.assigns.current_user_id
    device_id = conn.assigns.current_device_id
    kind = params["kind"]
    pushkey = params["pushkey"] || ""
    app_id = params["app_id"] || ""

    cond do
      # Deletion: kind nil or empty, or append=false with empty pushkey
      is_nil(kind) or kind == "" ->
        Repo.delete_all(
          from(p in "pushers",
            where: p.user_id == ^user_id and p.app_id == ^app_id and p.pushkey == ^pushkey
          )
        )

        json(conn, %{})

      pushkey == "" ->
        conn
        |> put_status(400)
        |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "pushkey required"})

      true ->
        row = %{
          user_id: user_id,
          device_id: device_id,
          kind: kind,
          app_id: app_id,
          app_display_name: params["app_display_name"] || "",
          device_display_name: params["device_display_name"] || "",
          pushkey: pushkey,
          lang: params["lang"] || "en",
          data: params["data"] || %{},
          enabled: Map.get(params, "enabled", true)
        }

        Repo.insert_all("pushers", [row],
          on_conflict:
            {:replace,
             [:kind, :app_display_name, :device_display_name, :lang, :data, :enabled, :device_id]},
          conflict_target: [:user_id, :app_id, :pushkey]
        )

        json(conn, %{})
    end
  end
end
