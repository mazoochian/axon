defmodule AxonWeb.Params do
  @moduledoc "Shared request-parameter parsing for controllers."

  @doc """
  Parses an integer parameter that may arrive as a query string or a JSON
  integer, falling back to `default` when absent or malformed and clamping
  the result to `min..max`.
  """
  def int(value, default, min, max) do
    parsed =
      case value do
        n when is_integer(n) ->
          n

        s when is_binary(s) ->
          case Integer.parse(s) do
            {n, ""} -> n
            _ -> default
          end

        _ ->
          default
      end

    parsed |> max(min) |> min(max)
  end

  @doc """
  Every value of a repeatable query parameter (`?v=a&v=b`), which Plug's
  default parser collapses to the last occurrence.
  """
  def query_values(%Plug.Conn{query_string: query_string}, keys) do
    keys = List.wrap(keys)

    for {k, v} <- URI.query_decoder(query_string), k in keys, do: v
  end

  def direction(nil), do: {:ok, "f"}
  def direction(dir) when dir in ["f", "b"], do: {:ok, dir}

  def direction(_),
    do: {:error, "M_INVALID_PARAM", "Query parameter dir must be one of \"f\" or \"b\""}

  def timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, "M_INVALID_PARAM", "Query parameter ts must be a non-negative integer"}
    end
  end

  def timestamp(_), do: {:error, "M_MISSING_PARAM", "Missing required parameter: ts"}
end
