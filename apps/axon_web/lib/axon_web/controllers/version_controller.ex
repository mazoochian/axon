defmodule AxonWeb.VersionController do
  use Phoenix.Controller, formats: [:json]

  def versions(conn, _params) do
    json(conn, %{
      "versions" => [
        "v1.1", "v1.2", "v1.3", "v1.4", "v1.5", "v1.6",
        "v1.7", "v1.8", "v1.9", "v1.10", "v1.11", "v1.12",
        "v1.13", "v1.14", "v1.15", "v1.16", "v1.17", "v1.18"
      ],
      "unstable_features" => %{
        "org.matrix.msc3814" => true
      }
    })
  end

  # GET /_matrix/client/v1/auth_metadata (MSC2965)
  def auth_metadata(conn, _params) do
    case AxonWeb.Oidc.metadata() do
      {:ok, doc} ->
        doc =
          if url = Application.get_env(:axon_web, :oidc, [])[:account_management_url],
            do: Map.put(doc, "account_management_uri", url),
            else: doc

        json(conn, doc)

      {:error, _reason} ->
        conn |> put_status(404) |> json(%{"errcode" => "M_UNRECOGNIZED", "error" => "OAuth 2.0 delegated auth not supported"})
    end
  end

  def media_config(conn, _params) do
    json(conn, %{"m.upload.size" => 104_857_600})
  end

  def empty_list_pushers(conn, _params) do
    json(conn, %{"pushers" => []})
  end

  def empty_list_3pid(conn, _params) do
    json(conn, %{"threepids" => []})
  end

  def empty_ok(conn, _params) do
    json(conn, %{})
  end

  def capabilities(conn, _params) do
    json(conn, %{
      "capabilities" => %{
        "m.change_password" => %{"enabled" => not AxonWeb.Oidc.enabled?()},
        "m.room_versions" => %{
          "default" => "11",
          "available" => %{
            "6" => "stable",
            "7" => "stable",
            "8" => "stable",
            "9" => "stable",
            "10" => "stable",
            "11" => "stable"
          }
        },
        "m.set_displayname" => %{"enabled" => true},
        "m.set_avatar_url" => %{"enabled" => true},
        "m.3pid_changes" => %{"enabled" => false}
      }
    })
  end
end
