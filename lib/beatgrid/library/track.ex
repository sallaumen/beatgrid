defmodule Beatgrid.Library.Track do
  @moduledoc """
  A physical audio file in the library. The row mirrors a file on disk
  (`rel_path` is relative to the library root); the DB never owns the file.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Beatgrid.Library.Normalize

  @type t :: %__MODULE__{}

  @formats ~w(mp3 m4a flac wav aac ogg other)a
  @statuses ~w(present missing quarantined)a
  @quality_issues ~w(missing_tags low_bitrate truncated corrupt not_audio too_short silent)a
  @loudness_measurement_origins ~w(library_file original_backup post_gain restore_backup)a

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "tracks" do
    field :rel_path, :string
    field :filename, :string
    field :content_sha256, :string
    field :file_size_bytes, :integer
    field :format, Ecto.Enum, values: @formats

    field :bitrate_kbps, :integer
    field :sample_rate_hz, :integer
    field :channels, :integer
    field :duration_ms, :integer

    field :tag_title, :string
    field :tag_artist, :string
    field :tag_album, :string
    field :tag_album_artist, :string
    field :tag_year, :integer
    field :tag_track_no, :integer
    field :tag_isrc, :string
    field :tag_genre, :string
    field :tag_comment, :string
    field :raw_tags, :map, default: %{}

    field :norm_artist, :string
    field :norm_title, :string

    field :source_playlist, :string
    field :genre_folder, :string
    field :status, Ecto.Enum, values: @statuses, default: :present
    field :quality_issues, {:array, Ecto.Enum}, values: @quality_issues, default: []

    field :rating, :integer
    field :personal_note, :string
    field :tags, {:array, :string}, default: []
    field :cue_points, {:array, :map}, default: []

    field :last_scanned_at, :utc_datetime

    field :bpm_detected, :float
    field :camelot_detected, :string
    field :analyzed_at, :utc_datetime

    field :loudness_lufs, :float
    field :true_peak_dbtp, :float
    field :loudness_attempted_at, :utc_datetime
    field :original_loudness_lufs, :float
    field :original_true_peak_dbtp, :float
    field :original_loudness_measured_at, :utc_datetime
    field :loudness_measurement_origin, Ecto.Enum, values: @loudness_measurement_origins
    field :gain_applied_db, :float
    field :gain_applied_at, :utc_datetime
    field :sc_attempted_at, :utc_datetime

    field :bpm_manual, :float
    field :camelot_manual, :string
    field :manual_fields, {:array, :string}, default: []

    field :gold_status, Ecto.Enum, values: [:candidate, :confirmed]
    field :gold_manual, :boolean
    field :youtube_views, :integer
    field :youtube_published_at, :date

    field :sc_match_confidence, Ecto.Enum, values: [:high, :medium, :low]
    field :sc_art_trusted, :boolean, default: true

    belongs_to :soundcharts_song, Beatgrid.Soundcharts.Song, foreign_key: :soundcharts_song_id

    timestamps()
  end

  @castable ~w(rel_path filename content_sha256 file_size_bytes format
               bitrate_kbps sample_rate_hz channels duration_ms
               tag_title tag_artist tag_album tag_album_artist tag_year
               tag_track_no tag_isrc tag_genre tag_comment raw_tags
               source_playlist genre_folder status quality_issues
               rating personal_note tags cue_points last_scanned_at sc_match_confidence
               sc_art_trusted bpm_detected camelot_detected analyzed_at
               loudness_lufs true_peak_dbtp loudness_attempted_at
               original_loudness_lufs original_true_peak_dbtp original_loudness_measured_at
               loudness_measurement_origin
               gain_applied_db gain_applied_at sc_attempted_at
               bpm_manual camelot_manual manual_fields
               gold_status gold_manual youtube_views youtube_published_at
               soundcharts_song_id)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(track, attrs) do
    track
    |> cast(attrs, @castable)
    |> validate_required([:rel_path, :filename, :format])
    |> validate_number(:rating, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> put_normalized()
    |> unique_constraint(:rel_path)
  end

  defp put_normalized(changeset) do
    changeset
    |> put_change(:norm_artist, Normalize.normalize(get_field(changeset, :tag_artist)))
    |> put_change(:norm_title, Normalize.normalize(get_field(changeset, :tag_title)))
  end

  @doc "Allowed `format` enum values."
  def formats, do: @formats

  @doc "Allowed `quality_issues` enum values."
  def quality_issues, do: @quality_issues

  @doc "Allowed `loudness_measurement_origin` enum values."
  def loudness_measurement_origins, do: @loudness_measurement_origins
end
