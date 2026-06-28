defmodule Beatgrid.Mixes.Segment do
  @moduledoc "One track within a mix: where it starts, its name, per-segment BPM/Camelot, and the library match."
  use Ecto.Schema

  import Ecto.Changeset

  alias Beatgrid.Library.Track
  alias Beatgrid.Mixes.Mix

  @type t :: %__MODULE__{}

  @name_sources [:description, :manual, :audio, :fingerprint]
  @confidences [:high, :medium, :low]

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "mix_segments" do
    field :position, :integer
    field :start_ms, :integer
    field :end_ms, :integer
    field :artist, :string
    field :title, :string
    field :name_source, Ecto.Enum, values: @name_sources
    field :bpm_detected, :float
    field :camelot_detected, :string
    field :match_confidence, Ecto.Enum, values: @confidences

    belongs_to :mix, Mix
    belongs_to :matched_track, Track

    timestamps()
  end

  @fields ~w(mix_id position start_ms end_ms artist title name_source bpm_detected
             camelot_detected matched_track_id match_confidence)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(segment, attrs) do
    segment
    |> cast(attrs, @fields)
    |> validate_required([:position, :start_ms])
  end
end
