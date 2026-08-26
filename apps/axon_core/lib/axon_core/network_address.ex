defmodule AxonCore.NetworkAddress do
  @moduledoc """
  Hostname resolution plus the private/reserved-range predicate that every
  SSRF guard in the server shares.

  Two places take a network location from an untrusted request and then open
  an outbound connection to it — `AxonMedia.UrlPreview` (the `url` query
  parameter of `/_matrix/client/v1/media/preview_url`) and
  `AxonFederation.AddressGuard` (the `:server_name` path segment of the
  remote-media download/thumbnail endpoints). Both need the identical
  answer to "is this address one an attacker could use to reach something
  behind the homeserver", so the ranges live here rather than being
  maintained twice and drifting apart.

  `resolve/1` deliberately returns *every* address a hostname answers with
  (A and AAAA both), because a caller that only checks the address it
  intends to dial can still be walked into a private one by a resolver that
  alternates answers. A literal IP host is returned as itself, unresolved.
  """

  import Bitwise

  @type address :: :inet.ip_address()

  @doc """
  Resolves `host` — a hostname or an IP literal, with or without surrounding
  brackets for IPv6 — to the full list of addresses it answers with.

  Returns `{:ok, [address]}` (never an empty list) or
  `{:error, {:dns_failed, reason}}`.
  """
  @spec resolve(binary()) :: {:ok, [address()]} | {:error, {:dns_failed, term()}}
  def resolve(host) when is_binary(host) do
    host_charlist = host |> strip_brackets() |> String.to_charlist()

    case :inet.parse_address(host_charlist) do
      {:ok, ip} ->
        {:ok, [ip]}

      {:error, :einval} ->
        case :inet.getaddrs(host_charlist, :inet) do
          {:ok, v4} -> {:ok, v4 ++ resolve_v6(host_charlist)}
          {:error, _} -> resolve_v6_only(host_charlist)
        end
    end
  end

  defp strip_brackets("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [inner, _] -> inner
      _ -> rest
    end
  end

  defp strip_brackets(host), do: host

  defp resolve_v6(host_charlist) do
    case :inet.getaddrs(host_charlist, :inet6) do
      {:ok, v6} -> v6
      {:error, _} -> []
    end
  end

  defp resolve_v6_only(host_charlist) do
    case :inet.getaddrs(host_charlist, :inet6) do
      {:ok, v6} -> {:ok, v6}
      {:error, reason} -> {:error, {:dns_failed, reason}}
    end
  end

  @doc """
  True for an address no outbound request driven by untrusted input may
  reach.

  IPv4: 10/8, 172.16/12, 192.168/16, 127/8 (loopback), 169.254/16
  (link-local, which is where cloud instance metadata lives), 0/8,
  100.64/10 (CGNAT), 224/4 (multicast), 240/4 (reserved).

  IPv6: `::/128`, `::1` loopback, fe80::/10 link-local, fc00::/7
  unique-local, and IPv4-mapped `::ffff:a.b.c.d` unwrapped and re-checked as
  IPv4 (otherwise `::ffff:127.0.0.1` walks straight past an IPv4-only
  check).
  """
  @spec private?(address()) :: boolean()
  def private?({10, _, _, _}), do: true
  def private?({127, _, _, _}), do: true
  def private?({169, 254, _, _}), do: true
  def private?({0, _, _, _}), do: true
  def private?({a, b, _, _}) when a == 172 and b in 16..31, do: true
  def private?({192, 168, _, _}), do: true
  def private?({100, b, _, _}) when b in 64..127, do: true
  def private?({a, _, _, _}) when a >= 224, do: true
  def private?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  def private?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def private?({a, _, _, _, _, _, _, _}) when (a &&& 0xFFC0) == 0xFE80, do: true
  def private?({a, _, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: true

  def private?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    private?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})
  end

  def private?(_), do: false

  @doc """
  Resolves `host` and returns `{:ok, addresses}` only if *none* of them is
  private, `{:error, :blocked_address}` otherwise (and the DNS error
  unchanged if resolution failed outright).

  Blocking when *any* answer is private, rather than only the one a caller
  would dial, is intentional: a hostname whose resolver hands back a mix of
  public and private answers has no legitimate reason to, and treating it as
  hostile costs nothing.
  """
  @spec check(binary()) :: {:ok, [address()]} | {:error, :blocked_address | {:dns_failed, term()}}
  def check(host) when is_binary(host) do
    with {:ok, addresses} <- resolve(host) do
      if Enum.any?(addresses, &private?/1) do
        {:error, :blocked_address}
      else
        {:ok, addresses}
      end
    end
  end
end
