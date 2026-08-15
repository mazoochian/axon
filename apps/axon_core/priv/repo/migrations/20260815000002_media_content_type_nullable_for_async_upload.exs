defmodule AxonCore.Repo.Migrations.MediaContentTypeNullableForAsyncUpload do
  use Ecto.Migration

  def change do
    alter table(:media) do
      modify :content_type, :text, null: true, from: {:text, null: false}
    end
  end
end
