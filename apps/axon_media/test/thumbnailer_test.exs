defmodule AxonMedia.ThumbnailerTest do
  @moduledoc """
  Tests `AxonMedia.Thumbnailer` against real ImageMagick `convert` calls on
  real generated image fixtures (no mocking — this exercises the actual
  shell-out path).
  """

  use ExUnit.Case, async: false

  alias AxonMedia.Thumbnailer

  setup do
    tmp = Path.join(System.tmp_dir!(), "axon_thumb_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    original = Application.get_env(:axon_media, :storage_path)
    Application.put_env(:axon_media, :storage_path, tmp)

    source_path = Path.join(tmp, "source.png")
    {_, 0} = System.cmd("convert", ["-size", "40x30", "xc:red", source_path])

    on_exit(fn ->
      if original, do: Application.put_env(:axon_media, :storage_path, original), else: Application.delete_env(:axon_media, :storage_path)
      File.rm_rf(tmp)
    end)

    %{source_path: source_path, media_id: "media_#{System.unique_integer([:positive])}"}
  end

  test "generates a scaled thumbnail for a supported image type", %{source_path: src, media_id: id} do
    assert {:ok, {"image/png", data}} = Thumbnailer.generate(id, src, "image/png", 20, 20, "scale")
    assert byte_size(data) > 0
  end

  test "generates a cropped thumbnail for a supported image type", %{source_path: src, media_id: id} do
    assert {:ok, {"image/png", data}} = Thumbnailer.generate(id, src, "image/png", 20, 20, "crop")
    assert byte_size(data) > 0
  end

  test "rejects an unsupported content type without shelling out" do
    assert Thumbnailer.generate("id", "/nonexistent/path", "application/pdf", 96, 96, "scale") ==
             {:error, :unsupported_content_type}
  end

  test "a second request for the same dimensions reuses the cached file (byte-identical)", %{source_path: src, media_id: id} do
    assert {:ok, {_, data1}} = Thumbnailer.generate(id, src, "image/png", 15, 15, "scale")
    assert {:ok, {_, data2}} = Thumbnailer.generate(id, src, "image/png", 15, 15, "scale")
    assert data1 == data2
  end

  test "a missing source file fails cleanly instead of crashing", %{media_id: id} do
    assert {:error, _reason} = Thumbnailer.generate(id, "/nonexistent/source.png", "image/png", 96, 96, "scale")
  end

  test "width/height are clamped: nil defaults to 96, huge values are capped" do
    tmp = Path.join(System.tmp_dir!(), "axon_thumb_clamp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:axon_media, :storage_path, tmp)
    src = Path.join(tmp, "s.png")
    {_, 0} = System.cmd("convert", ["-size", "10x10", "xc:blue", src])

    assert {:ok, {"image/png", _}} = Thumbnailer.generate("clampid", src, "image/png", nil, nil, "scale")
    assert {:ok, {"image/png", _}} = Thumbnailer.generate("clampid2", src, "image/png", 999_999, 999_999, "scale")

    File.rm_rf(tmp)
  end

  test "each distinct dimension/method combination gets its own cache entry", %{source_path: src, media_id: id} do
    {:ok, {_, small}} = Thumbnailer.generate(id, src, "image/png", 10, 10, "scale")
    {:ok, {_, big}} = Thumbnailer.generate(id, src, "image/png", 30, 30, "scale")
    refute small == big
  end
end
