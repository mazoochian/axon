defmodule AxonFederation.ServerResolver do
  @moduledoc """
  Resolves a Matrix server_name to a base URL for outbound federation
  requests (both the S2S API itself and `/_matrix/key/v2/server` lookups).

  Consults `:server_overrides` first (a `%{server_name => base_url}` map, set
  via `Application.put_env(:axon_federation, :server_overrides, %{...})`) so
  tests can point a server_name at a local loopback fake server without any
  DNS/well-known trickery. Production/dev config never sets this, so real
  deployments fall through unchanged to `/.well-known/matrix/server`
  delegation, then `https://<server_name>:8448`.
  """

  @user_agent "Axon/1.0"

  @doc "Returns the base URL (no trailing slash) to reach `server_name` at."
  @spec resolve(String.t()) :: String.t()
  def resolve(server_name) do
    case overrides()[server_name] do
      nil -> resolve_via_well_known(server_name)
      base_url -> base_url
    end
  end

  defp overrides, do: Application.get_env(:axon_federation, :server_overrides, %{})

  defp resolve_via_well_known(server_name) do
    well_known_url = "https://#{server_name}/.well-known/matrix/server"
    req = Finch.build(:get, well_known_url, [{"user-agent", @user_agent}])

    case Finch.request(req, Axon.Finch, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"m.server" => host}} -> "https://#{host}"
          _ -> "https://#{server_name}:8448"
        end

      _ ->
        "https://#{server_name}:8448"
    end
  rescue
    _ -> "https://#{server_name}:8448"
  end
end
