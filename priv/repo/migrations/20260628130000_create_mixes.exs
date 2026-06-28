defmodule Beatgrid.Repo.Migrations.CreateMixes do
  use Ecto.Migration

  def change do
    create table(:mixes, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :source, :string, null: false
      add :source_url, :string, null: false
      add :title, :string
      add :dj, :string
      add :duration_ms, :integer
      add :audio_path, :string
      add :description, :text
      add :status, :string, null: false, default: "downloading"
      add :error, :string
      add :analyzed_at, :utc_datetime
      add :cleanup_job_id, :integer
      add :audio_deleted_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:mixes, [:source_url])
    create index(:mixes, [:status])
    create index(:mixes, [:inserted_at])

    create table(:mix_segments, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :mix_id, references(:mixes, type: :uuid, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :start_ms, :integer, null: false
      add :end_ms, :integer
      add :artist, :string
      add :title, :string
      add :name_source, :string
      add :bpm_detected, :float
      add :camelot_detected, :string
      add :matched_track_id, references(:tracks, type: :uuid, on_delete: :nilify_all)
      add :match_confidence, :string
      timestamps(type: :utc_datetime)
    end

    create index(:mix_segments, [:mix_id, :position])
  end
end
