defmodule Beatgrid.Soundcharts.Song do
  @moduledoc """
  Cached Soundcharts song metadata (1 row per Soundcharts UUID). Persisted on
  first resolution and never re-fetched — the API quota is scarce.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "soundcharts_songs" do
    field :sc_uuid, :string
    field :isrc, :string
    field :name, :string
    field :credit_name, :string
    field :release_date, :date
    field :label, :string
    field :genres, {:array, :string}, default: []

    field :tempo_bpm, :float
    field :music_key, :integer
    field :music_mode, :integer
    field :camelot, :string
    field :energy, :float
    field :valence, :float
    field :danceability, :float
    field :acousticness, :float
    field :instrumentalness, :float
    field :liveness, :float
    field :loudness, :float
    field :speechiness, :float
    field :popularity, :integer

    field :raw, :map, default: %{}
    field :fetched_at, :utc_datetime

    timestamps()
  end

  @castable ~w(sc_uuid isrc name credit_name release_date label genres
               tempo_bpm music_key music_mode camelot energy valence danceability
               acousticness instrumentalness liveness loudness speechiness
               popularity raw fetched_at)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(song, attrs) do
    song
    |> cast(attrs, @castable)
    |> validate_required([:sc_uuid])
    |> unique_constraint(:sc_uuid)
  end
end
