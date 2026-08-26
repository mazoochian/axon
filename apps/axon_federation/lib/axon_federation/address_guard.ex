defmodule AxonFederation.AddressGuard do
  @moduledoc """
  SSRF guard for outbound requests whose destination comes from an untrusted
  request — specifically remote-media proxying, where the origin server name
  is a path segment of `/_matrix/media/v3/download/:server_name/:media_id`
  (unauthenticated, for old-client compatibility) and of its authenticated
  MSC3916 equivalent. Without this the endpoints are a pre-auth "connect to
  any host:port I name" primitive: cloud instance metadata at
  `169.254.169.254`, Postgres on loopback, internal admin panels, anything
  that trusts the homeserver's source IP.

  ## Why the *resolved* address, and why twice

  Checking the server-name string is not enough — `evil.test` can simply
  have an A record pointing at `10.0.0.5`. So the host is resolved and every
  address it answers with is checked against
  `AxonCore.NetworkAddress.private?/1` (the same ranges the url-preview
  guard uses).

  `check_base_url/1` is applied a second time *after* server resolution,
  because `.well-known/matrix/server` delegation lets the destination
  redirect us: a public `evil.test` can answer its well-known with
  `{"m.server": "127.0.0.1:5432"}`. The pre-resolution check on the
  server_name itself matters for the mirror-image reason — the well-known
  fetch is itself an outbound request to a caller-named host, so it has to
  be cleared before it happens, not after.

  ## Residual DNS-rebinding window

  `AxonMedia.UrlPreview` closes rebinding completely by connecting a raw
  `Mint.HTTP` socket to the literal address it validated. Federation traffic
  goes through Finch (for connection pooling and X-Matrix request signing),
  which resolves the hostname itself, so there is a narrow validate-then-
  connect window here that a resolver alternating answers could win.
  Rejecting a host when *any* of its answers is private (rather than just
  the one Finch would pick) makes that a genuinely racy attack rather than a
  reliable one; closing it outright means teaching the federation HTTP path
  to dial a pinned address, which is a larger change than this guard.

  ## The escape hatch

  `:axon_federation, :allow_private_addresses` disables the check. It is set
  by `config/test.exs` (every fake remote server in the suite is a Bandit
  listener on 127.0.0.1), by `config/dev.exs` (a second local Axon), and in
  prod only via `FEDERATION_ALLOW_PRIVATE_ADDRESSES`, which
  `complement/start.sh` sets because Complement's homeservers live on a
  private Docker network. There is no admin-facing knob beyond that
  environment variable, and it defaults off.
  """

  alias AxonCore.NetworkAddress

  @doc """
  Checks a Matrix `server_name` (`host` or `host:port`, IPv6 literals
  bracketed) before it is used as an outbound destination.

  Returns `:ok` or `{:error, :blocked_address}` — a DNS failure is reported
  as `:blocked_address` too, deliberately: the caller turns both into the
  same client-visible response as a connection failure, so probing can't
  distinguish "this internal host exists but is blocked" from "this name
  doesn't resolve".
  """
  @spec check_server_name(binary()) :: :ok | {:error, :blocked_address}
  def check_server_name(server_name) when is_binary(server_name) do
    check_host(host_of_server_name(server_name))
  end

  def check_server_name(_), do: {:error, :blocked_address}

  @doc """
  Checks the host of an already-built URL — the base URL server resolution
  produced, or a `Location` a remote handed back for us to follow.
  """
  @spec check_base_url(binary()) :: :ok | {:error, :blocked_address}
  def check_base_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> check_host(host)
      _ -> {:error, :blocked_address}
    end
  end

  def check_base_url(_), do: {:error, :blocked_address}

  @doc "True when the private-address check is switched off for this environment."
  @spec allow_private_addresses?() :: boolean()
  def allow_private_addresses? do
    Application.get_env(:axon_federation, :allow_private_addresses, false)
  end

  defp check_host(host) do
    if allow_private_addresses?() do
      :ok
    else
      case NetworkAddress.check(host) do
        {:ok, _addresses} -> :ok
        {:error, _} -> {:error, :blocked_address}
      end
    end
  end

  # A server_name is `hostname[:port]`, and an IPv6 literal is bracketed
  # (`[::1]:8448`) precisely so the colons inside it aren't the port
  # separator. Splitting on the last colon only when it follows a `]` — or
  # when there are no brackets at all — keeps `[::1]` intact instead of
  # handing `:inet.parse_address/1` the string `"[::1"`.
  defp host_of_server_name("[" <> _ = server_name) do
    case String.split(server_name, "]", parts: 2) do
      [bracketed, _rest] -> bracketed <> "]"
      _ -> server_name
    end
  end

  defp host_of_server_name(server_name) do
    server_name |> String.split(":", parts: 2) |> hd()
  end
end
