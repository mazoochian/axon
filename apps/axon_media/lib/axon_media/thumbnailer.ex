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

  # content type => {ImageMagick coder, cache file extension}
  @formats %{
    "image/jpeg" => {"jpeg", "jpg"},
    "image/png" => {"png", "png"},
    "image/gif" => {"gif", "gif"},
    "image/webp" => {"webp", "webp"}
  }
  @max_dimension 1600
  @resource_limits [
    ["-limit", "memory", "256MiB"],
    ["-limit", "map", "512MiB"],
    ["-limit", "disk", "1GiB"],
    ["-limit", "area", "128MP"],
    ["-limit", "width", "16KP"],
    ["-limit", "height", "16KP"],
    ["-limit", "time", "30"]
  ]

  @doc """
  Generates (or reuses a cached) thumbnail for `media_id`.

  `method` is `"crop"` or `"scale"` per the Matrix spec. Returns
  `{:ok, {content_type, binary}}`, `{:error, :unsupported_content_type}` if
  the source isn't a thumbnailable image, or `{:error, reason}` on failure.
  """
  def generate(media_id, source_path, content_type, width, height, method) do
    case Map.fetch(@formats, content_type) do
      {:ok, {coder, ext}} ->
        width = clamp(width)
        height = clamp(height)
        method = if method == "crop", do: "crop", else: "scale"
        cache_path = cache_path(media_id, width, height, method, ext)

        with :ok <- ensure_thumbnail(source_path, cache_path, coder, width, height, method),
             {:ok, data} <- File.read(cache_path) do
          {:ok, {content_type, data}}
        end

      :error ->
        {:error, :unsupported_content_type}
    end
  end

  defp ensure_thumbnail(source_path, cache_path, coder, width, height, method) do
    if File.exists?(cache_path),
      do: :ok,
      else: run_convert(source_path, cache_path, coder, width, height, method)
  end

  # The explicit coder prefix on both input and output stops ImageMagick
  # from sniffing the source format, so a file stored as image/png that is
  # really SVG/MVG/etc. fails to decode instead of reaching a riskier coder.
  # "[0]" selects the first frame only. Output goes to a temp file renamed
  # into place, so a concurrent reader never sees a partial thumbnail.
  defp run_convert(source_path, output_path, coder, width, height, method) do
    File.mkdir_p!(Path.dirname(output_path))
    tmp_path = "#{output_path}.#{System.unique_integer([:positive])}.tmp"

    args =
      List.flatten(@resource_limits) ++
        ["#{coder}:#{source_path}[0]"] ++
        resize_args(width, height, method) ++ ["#{coder}:#{tmp_path}"]

    case System.cmd("convert", args, stderr_to_stdout: true) do
      {_, 0} ->
        File.rename(tmp_path, output_path)

      {output, _status} ->
        File.rm(tmp_path)
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

  defp cache_path(media_id, width, height, method, ext) do
    dir = Path.join(AxonMedia.Store.base_dir(), "thumbnails")
    Path.join(dir, "#{media_id}-#{width}x#{height}-#{method}.#{ext}")
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
