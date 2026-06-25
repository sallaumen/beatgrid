defmodule Beatgrid.Sets.SetTrack do
  @moduledoc "Ordered membership of a track in a `RecSet` (join row carrying `position`)."
  use Ecto.Schema

  import Ecto.Changeset

  alias Beatgrid.Library.Track
  alias Beatgrid.Sets.RecSet

  @type t :: %__MODULE__{}

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "rec_set_tracks" do
    field :position, :integer

    belongs_to :rec_set, RecSet
    belongs_to :track, Track

    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(set_track, attrs) do
    set_track
    |> cast(attrs, [:rec_set_id, :track_id, :position])
    |> validate_required([:rec_set_id, :track_id, :position])
    |> unique_constraint([:rec_set_id, :track_id])
    |> assoc_constraint(:rec_set)
    |> assoc_constraint(:track)
  end
end
