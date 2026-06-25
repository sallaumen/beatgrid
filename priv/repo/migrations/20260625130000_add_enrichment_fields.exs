defmodule Beatgrid.Repo.Migrations.AddEnrichmentFields do
  use Ecto.Migration

  def change do
    alter table(:soundcharts_songs) do
      add :subgenres, {:array, :string}, default: []
      add :duration_seconds, :integer
      add :language_code, :string
      add :image_url, :string
      add :sc_artist_uuid, :string
      add :sc_artist_name, :string
      add :time_signature, :integer
    end

    alter table(:tracks) do
      add :sc_match_confidence, :string
    end
  end
end
