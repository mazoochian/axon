defmodule AxonRoom.ServerAcl do
  @moduledoc """
  `m.room.server_acl` enforcement — a network-layer allow/deny check on
  which remote servers may interact with a room over federation, per the
  Client-Server API's "Server ACLs" section
  (https://spec.matrix.org/v1.18/client-server-api/#server-acls) and the
  Server-Server API's "Server Access Control Lists (ACLs)" section, which
  lists the specific endpoints and PDU/EDU handling this must gate.

  Deliberately NOT part of `AxonRoom.AuthRules`'s auth-rules DAG checks —
  the spec is explicit that ACLs "do not restrict the events relative to
  the room DAG via authorisation rules, but instead act purely at the
  network layer to determine which servers are allowed to connect and
  interact with a given room." A server denied by an ACL added after it
  already has events/state in the room keeps those; only its *further*
  requests, PDUs, and EDUs get rejected going forward.
  """

  @doc """
  `current_state` is a `{type, state_key} => event` map, as returned by
  `AxonCore.EventStore.get_current_state/1` (via `event_to_map/1`) or
  `AxonRoom.RoomProcess.get_room_ctx/1`'s `current_state` field.

  Per spec, evaluated in order:
  1. No `m.room.server_acl` event in room state -> allow.
  2. `server_name` is an IP literal and `allow_ip_literals` is `false` -> deny.
  3. `server_name` matches an entry in `deny` -> deny.
  4. `server_name` matches an entry in `allow` -> allow.
  5. Otherwise -> deny.
  """
  def allowed?(current_state, server_name) when is_map(current_state) do
    case current_state[{"m.room.server_acl", ""}] do
      %{"content" => content} when is_map(content) -> allowed_by_content?(content, server_name)
      _ -> true
    end
  end

  @doc "Same algorithm, given the `m.room.server_acl` event's `content` directly."
  def allowed_by_content?(content, server_name) when is_map(content) do
    host = strip_port(server_name)

    cond do
      ip_literal?(host) and content["allow_ip_literals"] == false ->
        false

      matches_any?(host, content["deny"]) ->
        false

      matches_any?(host, content["allow"]) ->
        true

      true ->
        false
    end
  end

  # "the suspect server's port number must not be considered" — evil.com,
  # evil.com:8448, and evil.com:1234 must all match a rule for "evil.com".
  # A bracketed IPv6 literal (`[::1]` or `[::1]:8448`, per the server_name
  # grammar) needs its own case — naively splitting on ":" would otherwise
  # shatter the address itself, not just strip a port.
  defp strip_port("[" <> _ = server_name) do
    case Regex.run(~r/^\[([^\]]+)\]/, server_name) do
      [_, addr] -> addr
      _ -> server_name
    end
  end

  defp strip_port(server_name), do: server_name |> to_string() |> String.split(":") |> hd()

  defp ip_literal?(host) do
    match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp matches_any?(host, patterns) when is_list(patterns) do
    Enum.any?(patterns, &glob_match?(host, &1))
  end

  defp matches_any?(_host, _not_a_list), do: false

  defp glob_match?(host, pattern) when is_binary(pattern) do
    Regex.match?(glob_to_regex(pattern), host)
  end

  defp glob_match?(_host, _pattern), do: false

  # Glob syntax per spec: "*" matches any run of characters, "?" matches
  # exactly one, case-insensitive, and the match is anchored (the whole
  # server name must match, not a substring).
  defp glob_to_regex(pattern) do
    body =
      pattern
      |> String.graphemes()
      |> Enum.map(fn
        "*" -> ".*"
        "?" -> "."
        ch -> Regex.escape(ch)
      end)
      |> Enum.join()

    Regex.compile!("^#{body}$", "i")
  end
end
