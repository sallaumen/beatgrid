defmodule Beatgrid.Repo.Migrations.AddGoldAndYouTubeToTracks do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :gold_status, :string
      add :gold_manual, :boolean
      add :youtube_views, :bigint
      add :youtube_published_at, :date
    end
  end
end
