defmodule AxonWeb.HttpJson do
  @moduledoc "Outbound JSON-over-HTTP requests (identity servers, application services)."

  @timeout 10_000

  @doc """
  Sends `body` (JSON-encoded when not nil) and decodes a 2xx JSON response.
  Returns `{:ok, decoded}`, `{:error, :invalid_json}`,
  `{:error, {:http_error, status, raw_body}}` or `{:error, reason}`.
  """
  def request(method, url, headers, body \\ nil) do
    headers = [{"accept", "application/json"} | headers]

    {headers, encoded} =
      if is_nil(body),
        do: {headers, nil},
        else: {[{"content-type", "application/json"} | headers], Jason.encode!(body)}

    case Finch.request(Finch.build(method, url, headers, encoded), Axon.Finch,
           receive_timeout: @timeout
         ) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        case Jason.decode(resp_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  def bearer(nil), do: []
  def bearer(token), do: [{"authorization", "Bearer " <> token}]
end
