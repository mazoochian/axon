defmodule AxonWeb.UnrecognizedController do
  @moduledoc """
  Catch-all for `/_matrix/...` paths no route matches.

  The Matrix APIs distinguish two failure modes the router can't express on
  its own: a path this server doesn't implement at all (404 `M_UNRECOGNIZED`)
  and a real endpoint called with the wrong method (405 `M_UNRECOGNIZED`).
  Both are distinct from `M_NOT_FOUND`, which means "this endpoint exists and
  the thing you asked it for doesn't" — that one stays with the controllers
  that can actually tell.

  Phoenix has no built-in 405, so the method case is derived by re-asking the
  router whether any *other* method would have matched this same path.
  """
  use Phoenix.Controller, formats: [:json]

  # Every method the router routes. OPTIONS never reaches here (`AxonWeb.Plug.CORS`
  # answers preflight and halts before the router); HEAD is rewritten to GET by
  # `Plug.Head`.
  @methods ~w(GET POST PUT PATCH DELETE)

  def unrecognized(conn, _params) do
    {status, error} =
      if routed_under_another_method?(conn) do
        {405, "Unrecognized request method for this endpoint"}
      else
        {404, "Unrecognized request"}
      end

    conn
    |> put_status(status)
    |> json(%{"errcode" => "M_UNRECOGNIZED", "error" => error})
  end

  defp routed_under_another_method?(conn) do
    Enum.any?(@methods -- [conn.method], fn method ->
      case Phoenix.Router.route_info(AxonWeb.Router, method, conn.request_path, conn.host) do
        :error -> false
        # Matched this same catch-all under the other method, not a real route.
        %{plug: __MODULE__} -> false
        _ -> true
      end
    end)
  end
end
