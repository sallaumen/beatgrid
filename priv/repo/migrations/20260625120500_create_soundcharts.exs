defmodule Beatgrid.Repo.Migrations.CreateSoundcharts do
  use Ecto.Migration

  def change do
    create table(:soundcharts_songs, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :sc_uuid, :string, null: false
      add :isrc, :string
      add :name, :string
      add :credit_name, :string
      add :release_date, :date
      add :label, :string
      add :genres, {:array, :string}, null: false, default: []

      # Audio features
      add :tempo_bpm, :float
      add :music_key, :integer
      add :music_mode, :integer
      add :camelot, :string
      add :energy, :float
      add :valence, :float
      add :danceability, :float
      add :acousticness, :float
      add :instrumentalness, :float
      add :liveness, :float
      add :loudness, :float
      add :speechiness, :float
      add :popularity, :integer

      add :raw, :map, null: false, default: %{}
      add :fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create table(:soundcharts_artists, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :sc_uuid, :string, null: false
      add :name, :string
      add :country_code, :string
      add :genres, {:array, :string}, null: false, default: []
      add :career_stage, :string
      add :raw, :map, null: false, default: %{}
      add :fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Budget ledger — every Soundcharts call, with the x-quota-remaining header.
    create table(:api_calls, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :provider, :string, null: false, default: "soundcharts"
      add :endpoint, :string, null: false
      add :method, :string, null: false, default: "GET"
      add :request_params, :map, null: false, default: %{}
      add :http_status, :integer
      add :quota_remaining, :integer
      add :success, :boolean, null: false, default: false
      add :error, :map
      add :duration_ms, :integer
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:soundcharts_songs, [:sc_uuid])
    create_if_not_exists index(:soundcharts_songs, [:isrc])
    create_if_not_exists unique_index(:soundcharts_artists, [:sc_uuid])
    create_if_not_exists index(:api_calls, [:provider, :occurred_at])

    alter table(:tracks) do
      add :soundcharts_song_id,
          references(:soundcharts_songs, type: :uuid, on_delete: :nilify_all)
    end

    create_if_not_exists index(:tracks, [:soundcharts_song_id])
  end
end
