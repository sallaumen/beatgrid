defmodule Beatgrid.Repo.Migrations.CreateRecommendations do
  use Ecto.Migration

  def change do
    create table(:recommendations, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :artist, :string, null: false
      add :song, :string, null: false
      add :reason, :text
      add :youtube_query, :string
      add :genre_folder, :string
      add :track_id, references(:tracks, type: :uuid, on_delete: :delete_all)
      add :source, :string, null: false
      add :status, :string, null: false, default: "new"
      add :batch_id, :uuid
      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:recommendations, [:genre_folder, :inserted_at])
    create_if_not_exists index(:recommendations, [:track_id, :inserted_at])
    create_if_not_exists index(:recommendations, [:status])
  end
end
