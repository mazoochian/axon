defmodule AxonCore.MatrixId do
  @moduledoc """
  Parsing helpers for Matrix identifiers (`@user:server`, `!room:server`,
  `#alias:server`).

  Exists because the obvious-looking `id |> String.split(":") |> List.last()`
  is **wrong** for any server name carrying an explicit port. A Matrix server
  name is `hostname[:port]`, so `@charlie:example.com:8448` splits into three
  parts and `List.last/1` yields `"8448"` — the port — instead of
  `"example.com:8448"`. Every federation check that compared such a value
  against the requesting origin then failed, which is why a peer reachable
  on a non-default port could not join, invite, or be queried at all.

  The sigil and localpart may themselves never contain `:`, so splitting on
  the *first* colon is the correct and complete rule.
  """

  @doc """
  The server-name portion of a Matrix ID, including any explicit port.

  Returns `nil` for an identifier with no server part at all — notably a
  room-version-12 room ID, which is a bare hash (`!<hash>`) with no
  `:server` suffix by design (MSC4291). Callers comparing against a server
  name should treat `nil` as "not addressed to any particular server"
  rather than coercing it to a string.

      iex> AxonCore.MatrixId.server_name("@alice:example.com")
      "example.com"

      iex> AxonCore.MatrixId.server_name("@alice:example.com:8448")
      "example.com:8448"

      iex> AxonCore.MatrixId.server_name("!abc123")
      nil
  """
  def server_name(id) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      [_localpart, server] when server != "" -> server
      _ -> nil
    end
  end

  def server_name(_), do: nil

  @doc """
  True when `id` belongs to `server_name`. Always false for an identifier
  with no server part, which cannot belong to anyone.
  """
  def from_server?(id, server) when is_binary(server) do
    case server_name(id) do
      nil -> false
      s -> s == server
    end
  end

  def from_server?(_id, _server), do: false

  @server_name_re ~r/^(\[[0-9a-fA-F:]+\](:\d+)?|[^:\[\]]+(:\d+)?)$/

  @doc """
  True when `server` is a syntactically valid Matrix server name —
  `hostname[:port]`, an IPv6 literal in brackets, or an IPv4 address,
  each with an optional `:port` that must be all-digits. A non-numeric
  port (`localhost:http`) is the case this exists to catch (spec:
  "Non-numeric ports in server names are rejected").

      iex> AxonCore.MatrixId.valid_server_name?("example.com")
      true

      iex> AxonCore.MatrixId.valid_server_name?("example.com:8448")
      true

      iex> AxonCore.MatrixId.valid_server_name?("[::1]:8448")
      true

      iex> AxonCore.MatrixId.valid_server_name?("example.com:http")
      false
  """
  def valid_server_name?(server) when is_binary(server), do: server =~ @server_name_re
  def valid_server_name?(_), do: false
end
