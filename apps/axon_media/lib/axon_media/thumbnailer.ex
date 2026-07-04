defmodule AxonMedia.Thumbnailer do
  @moduledoc """
  Generates thumbnails for image media by shelling out to ImageMagick's
  `convert`. Kept file-based (rather than a NIF image library) so the only
  new runtime dependency is a single package in the release image.

  Thumbnails are cached on disk next to the original, keyed by the
  requested dimensions/method, so repeat requests for the same size don't
  re-encode.
  """

  require Logger

  @supported_content_types ~w(image/jpeg image/png image/gif image/webp)
  @max_dimension 1600

  @doc """
  Generates (or reuses a cached) thumbnail for `media_id`.

  `method` is `"crop"` or `"scale"` per the Matrix spec. Returns
  `{:ok, {content_type, binary}}`, `{:error, :unsupported_content_type}` if
  the source isn't a thumbnailable image, or `{:error, reason}` on failure.
  """
  def generate(media_id, source_path, content_type, width, height, method) do
    if content_type in @supported_content_types do
      width = clamp(width)
      height = clamp(height)
      method = if method == "crop", do: "crop", else: "scale"
      cache_path = cache_path(media_id, width, height, method, content_type)

      cond do
        File.exists?(cache_path) ->
          read_cached(cache_path, content_type)

        true ->
          with :ok <- run_convert(source_path, cache_path, width, height, method) do
            read_cached(cache_path, content_type)
          end
      end
    else
      {:error, :unsupported_content_type}
    end
  end

  defp read_cached(path, content_type) do
    case File.read(path) do
      {:ok, data} -> {:ok, {content_type, data}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ImageMagick infers the output format from output_path's extension, which
  # cache_path/4 already set to match the source content-type.
  defp run_convert(source_path, output_path, width, height, method) do
    File.mkdir_p!(Path.dirname(output_path))
    resize_args = resize_args(width, height, method)
    # "[0]" selects the first frame only — good enough for a thumbnail of an animated format.
    source = "#{source_path}[0]"

    case System.cmd("convert", [source | resize_args] ++ [output_path], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _status} ->
        Logger.warning("Thumbnail generation failed for #{source_path}: #{output}")
        {:error, :convert_failed}
    end
  rescue
    e in ErlangError ->
      Logger.warning("convert not available: #{inspect(e)}")
      {:error, :convert_unavailable}
  end

  defp resize_args(width, height, "crop") do
    ["-resize", "#{width}x#{height}^", "-gravity", "center", "-extent", "#{width}x#{height}"]
  end

  defp resize_args(width, height, "scale") do
    ["-resize", "#{width}x#{height}>"]
  end

  defp ext_for("image/jpeg"), do: "jpg"
  defp ext_for("image/png"), do: "png"
  defp ext_for("image/gif"), do: "gif"
  defp ext_for("image/webp"), do: "webp"

  defp cache_path(media_id, width, height, method, content_type) do
    dir = Path.join(AxonMedia.Store.base_dir(), "thumbnails")
    Path.join(dir, "#{media_id}-#{width}x#{height}-#{method}.#{ext_for(content_type)}")
  end

  defp clamp(nil), do: 96

  defp clamp(n) when is_integer(n), do: n |> max(1) |> min(@max_dimension)

  defp clamp(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> clamp(i)
      :error -> 96
    end
  end
end
