defmodule AxonWeb.ThirdPartyController do
  @moduledoc """
  Client-Server API "Third party networks" endpoints — a client asking what
  non-Matrix networks (IRC, etc.) this homeserver's bridges support, and
  looking up users/rooms across those bridges. Axon holds no third-party
  state of its own: every response here is built by proxying to whichever
  registered Application Service declared the relevant `protocols` entry
  (or, for the two reverse lookups, whichever AS's `users`/`aliases`
  namespace owns the given mxid/alias), via
  `AxonWeb.AppService.Client`'s `query_thirdparty_*` calls and
  `AxonWeb.AppService.Manager`'s protocol/namespace-ownership lookups.

  Two deliberate deviations from a literal reading of the spec, both
  matching what Synapse actually does and what clients actually expect:

    * The spec documents `404` for "no mapping was found" on the lookup
      endpoints. A lookup that reaches an AS and simply matches nothing —
      or whose AS is briefly unreachable — returns `200 []` here instead.
      This is best-effort directory discovery: "nothing matched" is a more
      useful answer to "what matches?" than an opaque error, and Synapse's
      own `ThirdPartyUserServlet`/`ThirdPartyLocationServlet` likewise
      return a possibly-empty list with a 200. `404 M_NOT_FOUND` is
      reserved for the one case that really is "unknown": no registered AS
      declares the requested `:protocol` at all.

    * If more than one registered AS declares the *same* protocol name,
      only the first is queried for `/thirdparty/protocol/:protocol` and
      the `/:protocol`-suffixed user/location lookups. Merging several
      ASes' metadata for one protocol id isn't spec-mandated, and real
      deployments practically never have two bridges claiming the same one.
  """

  use Phoenix.Controller, formats: [:json]

  alias AxonWeb.AppService.{Client, Manager}

  # GET /_matrix/client/v3/thirdparty/protocols
  #
  # Queries every distinct registered protocol concurrently rather than one
  # at a time — a serial reduce here means one slow/unreachable bridge's
  # full request timeout is paid by every protocol queried after it, so a
  # handful of dead bridges could stall this endpoint for tens of seconds.
  def protocols(conn, _params) do
    result =
      Manager.all_protocols()
      |> Task.async_stream(&{&1, fetch_protocol(&1)},
        max_concurrency: 8,
        timeout: 5_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {protocol, {:ok, metadata}}}, acc -> Map.put(acc, protocol, metadata)
        {:ok, {_protocol, :error}}, acc -> acc
        {:exit, _reason}, acc -> acc
      end)

    json(conn, result)
  end

  # GET /_matrix/client/v3/thirdparty/protocol/:protocol
  def protocol(conn, %{"protocol" => protocol}) do
    case fetch_protocol(protocol) do
      {:ok, metadata} -> json(conn, metadata)
      :error -> unknown_protocol(conn, protocol)
    end
  end

  # GET /_matrix/client/v3/thirdparty/user?userid=...
  # Reverse lookup: what third-party identity does this Matrix user have?
  # There's no `protocol` in the request to select an AS by, so this asks
  # whichever AS's `users` namespace owns the mxid.
  def user(conn, %{"userid" => user_id} = params) do
    case Manager.registration_owning_user(user_id) do
      nil -> json(conn, [])
      reg -> json(conn, query_list(reg, :user, nil, Map.take(params, ["userid"])))
    end
  end

  def user(conn, _params), do: missing_param(conn, "userid")

  # GET /_matrix/client/v3/thirdparty/user/:protocol?field=...
  # Forward lookup: find Matrix user ids matching third-party search fields.
  def user_by_protocol(conn, %{"protocol" => protocol} = params) do
    case Manager.registrations_for_protocol(protocol) do
      [] -> unknown_protocol(conn, protocol)
      [reg | _] -> json(conn, query_list(reg, :user, protocol, search_fields(params)))
    end
  end

  # GET /_matrix/client/v3/thirdparty/location?alias=...
  def location(conn, %{"alias" => room_alias} = params) do
    case Manager.registration_owning_alias(room_alias) do
      nil -> json(conn, [])
      reg -> json(conn, query_list(reg, :location, nil, Map.take(params, ["alias"])))
    end
  end

  def location(conn, _params), do: missing_param(conn, "alias")

  # GET /_matrix/client/v3/thirdparty/location/:protocol?field=...
  def location_by_protocol(conn, %{"protocol" => protocol} = params) do
    case Manager.registrations_for_protocol(protocol) do
      [] -> unknown_protocol(conn, protocol)
      [reg | _] -> json(conn, query_list(reg, :location, protocol, search_fields(params)))
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

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

  # The protocol-specific search fields are "whatever the protocol's
  # `user_fields`/`location_fields` say", so everything in the query string
  # is forwarded verbatim — minus the path parameter Phoenix merged in, and
  # minus `access_token`, which is axon's own auth credential and has no
  # business being handed to a bridge (Synapse pops it here too).
  defp search_fields(params), do: Map.drop(params, ["protocol", "access_token"])

  # A malformed or unreachable AS response degrades to an empty result list
  # rather than a 5xx — see this module's moduledoc.
  defp query_list(reg, :user, protocol, params) do
    unwrap(Client.query_thirdparty_user(reg, protocol, params))
  end

  defp query_list(reg, :location, protocol, params) do
    unwrap(Client.query_thirdparty_location(reg, protocol, params))
  end

  defp unwrap({:ok, list}) when is_list(list), do: list
  defp unwrap(_), do: []

  defp unknown_protocol(conn, protocol) do
    conn
    |> put_status(404)
    |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Unknown protocol #{protocol}"})
  end

  defp missing_param(conn, name) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "#{name} is required"})
  end
end
