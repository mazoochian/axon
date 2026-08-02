defmodule AxonWeb.ThirdPartyController do
  @moduledoc """
  Client-Server API "Third party networks" endpoints — a client asking
  what non-Matrix networks (IRC, etc.) this homeserver's bridges support,
  and looking up users/rooms across that bridge. Every response here is
  built by proxying to whichever registered Application Service(s)
  declared the relevant `protocols` entry (or, for the reverse lookups,
  whichever AS's `users`/`aliases` namespace owns the given mxid/alias) —
  see `AxonWeb.AppService.Client`'s `query_thirdparty_*` functions and
  `AxonWeb.AppService.Manager`'s protocol/namespace-ownership lookups.

  Simplification, worth noting: if more than one registered AS declares
  the *same* protocol name, only the first one found is queried for
  `GET /thirdparty/protocol/:protocol` and the `/:protocol`-suffixed
  user/location lookups — merging multiple ASes' metadata for one
  protocol name isn't spec-mandated and real deployments practically
  never have two bridges claiming the same protocol id.
  """

  use Phoenix.Controller, formats: [:json]

  alias AxonWeb.AppService.{Client, Manager}

  # GET /_matrix/client/v3/thirdparty/protocols
  def protocols(conn, _params) do
    result =
      Manager.all_protocols()
      |> Enum.reduce(%{}, fn protocol, acc ->
        case fetch_protocol(protocol) do
          {:ok, metadata} -> Map.put(acc, protocol, metadata)
          :error -> acc
        end
      end)

    json(conn, result)
  end

  # GET /_matrix/client/v3/thirdparty/protocol/:protocol
  def protocol(conn, %{"protocol" => protocol}) do
    case fetch_protocol(protocol) do
      {:ok, metadata} ->
        json(conn, metadata)

      :error ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Unknown protocol #{protocol}"})
    end
  end

  defp fetch_protocol(protocol) do
    case Manager.registrations_for_protocol(protocol) do
      [] ->
        :error

      [reg | _] ->
        case Client.query_thirdparty_protocol(reg, protocol) do
          {:ok, metadata} -> {:ok, metadata}
          {:error, _} -> :error
        end
    end
  end

  # GET /_matrix/client/v3/thirdparty/user?userid=...
  # Reverse lookup: what third-party identity does this Matrix user have?
  # Asks whichever AS's `users` namespace owns userid — there's no
  # `protocol` to pick a specific AS by here.
  def user(conn, %{"userid" => user_id} = params) do
    case Manager.registration_owning_user(user_id) do
      nil ->
        json(conn, [])

      reg ->
        json(conn, query_list(reg, :user, nil, Map.take(params, ["userid"])))
    end
  end

  def user(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "userid required"})
  end

  # GET /_matrix/client/v3/thirdparty/user/:protocol?field=...
  # Forward lookup: find Matrix user ids matching third-party search fields.
  def user_by_protocol(conn, %{"protocol" => protocol} = params) do
    case Manager.registrations_for_protocol(protocol) do
      [] ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Unknown protocol #{protocol}"})

      [reg | _] ->
        json(conn, query_list(reg, :user, protocol, Map.delete(params, "protocol")))
    end
  end

  # GET /_matrix/client/v3/thirdparty/location?alias=...
  # Reverse lookup: what third-party location does this Matrix alias map to?
  def location(conn, %{"alias" => room_alias} = params) do
    case Manager.registration_owning_alias(room_alias) do
      nil ->
        json(conn, [])

      reg ->
        json(conn, query_list(reg, :location, nil, Map.take(params, ["alias"])))
    end
  end

  def location(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "alias required"})
  end

  # GET /_matrix/client/v3/thirdparty/location/:protocol?field=...
  def location_by_protocol(conn, %{"protocol" => protocol} = params) do
    case Manager.registrations_for_protocol(protocol) do
      [] ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Unknown protocol #{protocol}"})

      [reg | _] ->
        json(conn, query_list(reg, :location, protocol, Map.delete(params, "protocol")))
    end
  end

  # A malformed/unreachable AS response degrades to an empty result list
  # rather than a 5xx — the caller asked "what matches", and "nothing
  # matched" (possibly because the bridge is briefly down) is a more
  # useful answer than an opaque server error for what's fundamentally a
  # best-effort directory-discovery feature.
  defp query_list(reg, :user, protocol, params) do
    case Client.query_thirdparty_user(reg, protocol, params) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp query_list(reg, :location, protocol, params) do
    case Client.query_thirdparty_location(reg, protocol, params) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
