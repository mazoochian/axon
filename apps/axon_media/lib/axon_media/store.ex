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

  @doc "Upload binary data. Returns {:ok, media_id} or {:error, reason}."
  def upload(user_id, content_type, data, server_name) do
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
          created_at: DateTime.utc_now(:microsecond)
        }
      ])

      {:ok, media_id}
    end
  end

  @doc "Download local media. Returns {:ok, {content_type, binary}} or {:error, :not_found}."
  def download(media_id) do
    case Repo.one(
           from(m in "media",
             where: m.media_id == ^media_id,
             select: %{
               content_type: m.content_type,
               storage_path: m.storage_path,
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
        {:error, :not_found}

      %{content_type: ct, storage_path: path} ->
        case File.read(path) do
          {:ok, data} -> {:ok, {ct, data}}
          {:error, _} -> {:error, :not_found}
        end
    end
  end

  @doc "Look up content-type for a media_id without reading the file. Returns nil for quarantined media."
  def get_meta(media_id) do
    Repo.one(
      from(m in "media",
        where: m.media_id == ^media_id and m.quarantined == false,
        select: %{
          content_type: m.content_type,
          origin_server: m.origin_server,
          storage_path: m.storage_path
        }
      )
    )
  end
end
