defmodule AxonMedia do
  @moduledoc """
  Documentation for `AxonMedia`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> AxonMedia.hello()
      :world

  """
  def hello do
    :world
  end

  @doc "Maximum upload size in bytes, enforced on upload and advertised as `m.upload.size`."
  def max_upload_bytes, do: Application.get_env(:axon_media, :max_upload_bytes, 104_857_600)
end
