defmodule AxonWeb.AppService.RegistrationYaml do
  @moduledoc """
  A deliberately narrow YAML reader for a single, fixed shape: the
  application service registration files Complement writes into every
  homeserver container it deploys with a blueprint `ApplicationServices`
  entry (`/complement/appservice/<id>.yaml` — the same Synapse-style
  registration format Synapse and Dendrite both read directly). Axon
  previously only ever read its own hand-authored `appservices.json`, so
  these files existed in the container but were never loaded — any test
  registering an application service via a blueprint silently had no
  working appservice at all.

  This is NOT a general YAML parser — it has no business being one. The
  generator on the other end (`generateASRegistrationYaml` in
  Complement's own `internal/docker/builder.go`) only ever emits one
  exact, fixed structure:

      id: <string>
      hs_token: <string>
      as_token: <string>
      url: '<string>'
      sender_localpart: <string>
      rate_limited: <bool>
      de.sorunome.msc2409.push_ephemeral: <bool>
      push_ephemeral: <bool>
      org.matrix.msc3202: <bool>
      namespaces:
        users:
          - exclusive: <bool>
            regex: <string>
        rooms: []
        aliases: []

  Handles exactly that: flat top-level `key: value` scalars, single-quoted
  string values, `true`/`false` literals, and one `namespaces.users` list
  of `exclusive`/`regex` maps (the only namespace kind Complement's
  generator ever populates — `rooms`/`aliases` are always the literal
  empty list). Produces the same string-keyed map shape
  `AxonWeb.AppService.Manager`'s JSON loader already produces, so
  downstream matching/dispatch code doesn't need to know which loader an
  registration came from.
  """

  @doc "Parses one registration YAML file's contents. Returns {:ok, map} or {:error, reason}."
  def parse(contents) do
    lines = String.split(contents, "\n")
    {top, rest} = take_top_level(lines, %{})

    users =
      rest
      |> Enum.drop_while(&(&1 != "namespaces:"))
      |> parse_namespaces_users()

    {:ok, Map.put(top, "namespaces", %{"users" => users, "rooms" => [], "aliases" => []})}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Top-level (zero-indent) "key: value" scalar lines, stopping at the
  # first nested block ("namespaces:", which has no value on its own
  # line — every scalar line here does).
  defp take_top_level(["namespaces:" | _] = lines, acc), do: {acc, lines}
  defp take_top_level([], acc), do: {acc, []}

  defp take_top_level([line | rest], acc) do
    case String.split(line, ":", parts: 2) do
      [key, value] when key != "" ->
        take_top_level(rest, Map.put(acc, key, parse_scalar(String.trim(value))))

      _ ->
        take_top_level(rest, acc)
    end
  end

  # Only the first "- exclusive: ..." / "regex: ..." list item is ever
  # generated, but walk every "- "-prefixed entry at the expected 4-space
  # indent under "namespaces:\n  users:\n" so this doesn't silently drop
  # a second one if the generator ever changes.
  defp parse_namespaces_users(lines) do
    lines
    |> Enum.drop_while(&(&1 != "  users:"))
    |> Enum.drop(1)
    |> Enum.take_while(&String.starts_with?(&1, "    "))
    |> Enum.chunk_while(
      nil,
      fn line, acc ->
        trimmed = String.trim_leading(line, " ")

        if String.starts_with?(trimmed, "- ") do
          entry = parse_list_item_kv(String.trim_leading(trimmed, "- "))
          if acc, do: {:cont, acc, entry}, else: {:cont, entry}
        else
          {:cont, Map.merge(acc || %{}, parse_list_item_kv(trimmed))}
        end
      end,
      fn acc -> {:cont, acc, nil} end
    )
    |> Enum.reject(&is_nil/1)
  end

  defp parse_list_item_kv(text) do
    case String.split(text, ":", parts: 2) do
      [key, value] -> %{String.trim(key) => parse_scalar(String.trim(value))}
      _ -> %{}
    end
  end

  defp parse_scalar("true"), do: true
  defp parse_scalar("false"), do: false
  defp parse_scalar("[]"), do: []
  defp parse_scalar("'" <> rest), do: String.trim_trailing(rest, "'")
  defp parse_scalar("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp parse_scalar(value), do: value
end
