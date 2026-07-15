defmodule AxonMedia.StoreTest do
  @moduledoc """
  Tests `AxonMedia.Store` (filesystem media storage backend) against a real
  temp directory and Postgres (via `AxonMedia.DataCase`).
  """

  use AxonMedia.DataCase, async: false

  alias AxonMedia.Store

  setup do
    tmp = Path.join(System.tmp_dir!(), "axon_media_test_#{System.unique_integer([:positive])}")
    original = Application.get_env(:axon_media, :storage_path)
    Application.put_env(:axon_media, :storage_path, tmp)

    on_exit(fn ->
      if original,
        do: Application.put_env(:axon_media, :storage_path, original),
        else: Application.delete_env(:axon_media, :storage_path)

      File.rm_rf(tmp)
    end)

    %{tmp: tmp}
  end

  test "base_dir/0 reflects the configured storage_path", %{tmp: tmp} do
    assert Store.base_dir() == tmp
  end

  test "upload persists the file to disk and a DB row, download reads it back" do
    data = "hello world binary content"
    assert {:ok, media_id} = Store.upload("@alice:localhost", "text/plain", data, "localhost")
    assert is_binary(media_id)

    assert {:ok, {"text/plain", ^data}} = Store.download(media_id)
  end

  test "the uploaded file actually lands on disk under base_dir", %{tmp: tmp} do
    {:ok, media_id} = Store.upload("@alice:localhost", "text/plain", "content", "localhost")
    assert File.exists?(Path.join(tmp, media_id))
  end

  test "download of an unknown media_id is not_found" do
    assert Store.download("nonexistent_media_id") == {:error, :not_found}
  end

  test "get_meta returns content_type/origin_server without reading the file" do
    {:ok, media_id} = Store.upload("@alice:localhost", "image/png", "fakepngdata", "localhost")

    assert %{content_type: "image/png", origin_server: "localhost"} = Store.get_meta(media_id)
  end

  test "get_meta for an unknown media_id is nil" do
    assert Store.get_meta("nonexistent") == nil
  end

  test "two uploads get distinct media_ids" do
    {:ok, id1} = Store.upload("@alice:localhost", "text/plain", "a", "localhost")
    {:ok, id2} = Store.upload("@alice:localhost", "text/plain", "b", "localhost")
    refute id1 == id2
  end

  describe "download/1 edge cases" do
    test "quarantined media is reported as not_found, not a distinct error" do
      {:ok, media_id} = Store.upload("@alice:localhost", "text/plain", "secret", "localhost")

      {1, _} =
        Repo.update_all(
          Ecto.Query.from(m in "media", where: m.media_id == ^media_id),
          set: [quarantined: true]
        )

      assert Store.download(media_id) == {:error, :not_found}
    end

    test "a media row with no storage_path is not_found" do
      now = DateTime.utc_now(:microsecond)

      Repo.insert_all("media", [
        %{
          media_id: "no_path_media",
          origin_server: "localhost",
          content_type: "text/plain",
          file_size: 0,
          storage_path: nil,
          uploader: "@alice:localhost",
          created_at: now
        }
      ])

      assert Store.download("no_path_media") == {:error, :not_found}
    end

    test "a media row whose file was removed from disk is not_found, not a crash" do
      {:ok, media_id} = Store.upload("@alice:localhost", "text/plain", "content", "localhost")

      %{storage_path: path} =
        Repo.one(
          Ecto.Query.from(m in "media",
            where: m.media_id == ^media_id,
            select: %{storage_path: m.storage_path}
          )
        )

      File.rm!(path)

      assert Store.download(media_id) == {:error, :not_found}
    end
  end
end
