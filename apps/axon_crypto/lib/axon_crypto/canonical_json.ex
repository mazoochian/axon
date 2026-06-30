defmodule AxonCrypto.CanonicalJSON do
  @moduledoc """
  Matrix canonical JSON encoding.

  Spec: https://spec.matrix.org/latest/appendices/#canonical-json
  Keys must be sorted lexicographically, no insignificant whitespace, no floats.
  """

  @spec encode(term()) :: iodata()
  def encode(value) when is_map(value) and not is_struct(value) do
    pairs =
      value
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> [encode_string(k), ?:, encode(v)] end)
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end

  def encode(value) when is_list(value) do
    items = value |> Enum.map(&encode/1) |> Enum.intersperse(?,)
    [?[, items, ?]]
  end

  def encode(value) when is_binary(value), do: encode_string(value)

  def encode(value) when is_integer(value), do: Integer.to_string(value)

  def encode(value) when is_float(value) do
    raise ArgumentError,
          "Float values are not permitted in Matrix canonical JSON: #{inspect(value)}"
  end

  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(nil), do: "null"

  @spec encode_to_binary(term()) :: binary()
  def encode_to_binary(value), do: value |> encode() |> IO.iodata_to_binary()

  defp encode_string(str) when is_binary(str) do
    [?", escape_string(str), ?"]
  end

  defp escape_string(str) do
    str
    |> String.to_charlist()
    |> Enum.flat_map(&escape_char/1)
    |> List.to_string()
  end

  # Characters that must be escaped per JSON spec
  defp escape_char(?"), do: [?\\, ?"]
  defp escape_char(?\\), do: [?\\, ?\\]
  defp escape_char(?\b), do: [?\\, ?b]
  defp escape_char(?\f), do: [?\\, ?f]
  defp escape_char(?\n), do: [?\\, ?n]
  defp escape_char(?\r), do: [?\\, ?r]
  defp escape_char(?\t), do: [?\\, ?t]

  # Control characters U+0000 through U+001F must be escaped
  defp escape_char(c) when c < 0x20 do
    hex = Integer.to_string(c, 16) |> String.pad_leading(4, "0") |> String.downcase()
    [?\\, ?u, String.to_charlist(hex)]
  end

  defp escape_char(c), do: [c]
end
