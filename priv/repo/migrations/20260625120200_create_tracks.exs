defmodule Beatgrid.Repo.Migrations.CreateTracks do
  use Ecto.Migration

  def change do
    create table(:tracks, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false

      # File identity (the on-disk source of truth)
      add :rel_path, :string, null: false
      add :filename, :string, null: false
      add :content_sha256, :string
      add :file_size_bytes, :bigint
      add :format, :string, null: false

      # Audio properties
      add :bitrate_kbps, :integer
      add :sample_rate_hz, :integer
      add :channels, :integer
      add :duration_ms, :integer

      # ID3 tags
      add :tag_title, :string
      add :tag_artist, :string
      add :tag_album, :string
      add :tag_album_artist, :string
      add :tag_year, :integer
      add :tag_track_no, :integer
      add :tag_isrc, :string
      add :tag_genre, :string
      add :tag_comment, :text
      add :raw_tags, :map, null: false, default: %{}

      # Normalized for fuzzy matching
      add :norm_artist, :string
      add :norm_title, :string

      # Organization
      add :source_playlist, :string
      add :genre_folder, :string
      add :status, :string, null: false, default: "present"
      add :quality_issues, {:array, :string}, null: false, default: []

      # Personal
      add :rating, :integer
      add :personal_note, :text

      add :last_scanned_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:tracks, [:rel_path])
    create_if_not_exists index(:tracks, [:norm_artist, :norm_title])
    create_if_not_exists index(:tracks, [:content_sha256])
    create_if_not_exists index(:tracks, [:status])
    create_if_not_exists index(:tracks, [:genre_folder])
  end
end
