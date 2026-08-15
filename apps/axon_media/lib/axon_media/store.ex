defmodule AxonMedia.Store do
  @moduledoc """
  Local filesystem media storage backend.

  Files are stored under a configurable base directory (defaults to
  `$TMPDIR/axon_media`). Each file is named by its media_id.
  """

  alias AxonCore.Repo
  import Ecto.Query

  # 18 bytes → 24 base64url chars
  @id_bytes 18

  def base_dir do
    Application.get_env(:axon_media, :storage_path, Path.join(System.tmp_dir!(), "axon_media"))
  end

  @doc """
  Upload binary data. `filename`, if given, is the client-supplied
  `?filename=` upload param — persisted so a later download can return it
  in `Content-Disposition` per spec ("If the upload was made with a
  filename, this header MUST contain the same filename").

  Returns {:ok, media_id} or {:error, reason}.
  """
  def upload(user_id, content_type, data, server_name, filename \\ nil) do
    media_id = :crypto.strong_rand_bytes(@id_bytes) |> Base.url_encode64(padding: false)
    dir = base_dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, media_id)

    with :ok <- File.write(path, data) do
      Repo.insert_all("media", [
        %{
          media_id: media_id,
          origin_server: server_name,
          content_type: content_type,
          file_size: byte_size(data),
          storage_path: path,
          uploader: user_id,
          filename: filename,
          created_at: DateTime.utc_now(:microsecond)
        }
      ])

      {:ok, media_id}
    end
  end

  @doc """
  Download local media. Returns `{:ok, %{content_type:, data:, filename:}}`
  (filename is `nil` when the upload didn't supply one), `{:error, :not_found}`,
  or `{:error, :not_yet_uploaded}` for a media ID reserved via `create_pending/2`
  (async upload, MSC2246) that hasn't had its content `PUT` yet.
  """
  def download(media_id) do
    case Repo.one(
           from(m in "media",
             where: m.media_id == ^media_id,
             select: %{
               content_type: m.content_type,
               storage_path: m.storage_path,
               filename: m.filename,
               quarantined: m.quarantined
             }
           )
         ) do
      nil ->
        {:error, :not_found}

      # Quarantined media is served as if it doesn't exist (matches
      # Synapse) -- not a distinct error, so a client/scraper can't use the
      # response shape to tell "never existed" apart from "admin pulled it".
      %{quarantined: true} ->
        {:error, :not_found}

      %{storage_path: nil} ->
        {:error, :not_yet_uploaded}

      %{content_type: ct, storage_path: path, filename: filename} ->
        case File.read(path) do
          {:ok, data} -> {:ok, %{content_type: ct, data: data, filename: filename}}
          {:error, _} -> {:error, :not_found}
        end
    end
  end

  @doc """
  Reserves an MXC URI for a later async upload (`POST /media/v1/create`,
  MSC2246) — a "media" row with no content yet, filled in by
  `complete_upload/5` once the client `PUT`s the bytes. `download/1` on a
  media_id in this state returns `{:error, :not_yet_uploaded}`.
  """
  def create_pending(user_id, server_name) do
    media_id = :crypto.strong_rand_bytes(@id_bytes) |> Base.url_encode64(padding: false)

    Repo.insert_all("media", [
      %{
        media_id: media_id,
        origin_server: server_name,
        uploader: user_id,
        created_at: DateTime.utc_now(:microsecond)
      }
    ])

    {:ok, media_id}
  end

  @doc """
  Checks whether `media_id` is a pending reservation `user_id` may fill —
  same outcomes as `complete_upload/5` minus actually writing anything.
  Lets a caller reject a request (e.g. an already-uploaded conflict)
  before spending the work of reading its body.
  """
  def complete_upload_precheck(media_id, user_id) do
    case pending_upload_lookup(media_id) do
      nil -> {:error, :not_found}
      %{uploader: uploader} when uploader != user_id -> {:error, :forbidden}
      %{storage_path: path} when not is_nil(path) -> {:error, :already_uploaded}
      _ -> :ok
    end
  end

  @doc """
  Fills in a media ID previously reserved with `create_pending/2` (the
  `PUT` half of async upload). Returns:
  - `{:error, :not_found}` — no such media_id
  - `{:error, :forbidden}` — reserved by a different user
  - `{:error, :already_uploaded}` — already has content (spec:
    `M_CANNOT_OVERWRITE_MEDIA`)
  - `{:ok, media_id}` on success
  """
  def complete_upload(media_id, user_id, content_type, data, filename \\ nil) do
    with :ok <- complete_upload_precheck(media_id, user_id) do
      dir = base_dir()
      File.mkdir_p!(dir)
      path = Path.join(dir, media_id)

      with :ok <- File.write(path, data) do
        Repo.update_all(
          from(m in "media", where: m.media_id == ^media_id),
          set: [
            content_type: content_type,
            file_size: byte_size(data),
            storage_path: path,
            filename: filename
          ]
        )

        {:ok, media_id}
      end
    end
  end

  defp pending_upload_lookup(media_id) do
    Repo.one(
      from(m in "media",
        where: m.media_id == ^media_id,
        select: %{uploader: m.uploader, storage_path: m.storage_path}
      )
    )
  end

  @doc "Look up content-type for a media_id without reading the file. Returns nil for quarantined media."
  def get_meta(media_id) do
    Repo.one(
      from(m in "media",
        where: m.media_id == ^media_id and m.quarantined == false,
        select: %{
          content_type: m.content_type,
          origin_server: m.origin_server,
          storage_path: m.storage_path,
          filename: m.filename
        }
      )
    )
  end
end
