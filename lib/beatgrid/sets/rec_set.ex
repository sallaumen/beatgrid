defmodule Beatgrid.Sets.RecSet do
  @moduledoc "A named, ordered harmonic set (a DJ set / crate the user is building)."
  use Ecto.Schema

  import Ecto.Changeset

  alias Beatgrid.Sets.SetTrack

  @type t :: %__MODULE__{}

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "rec_sets" do
    field :name, :string

    has_many :set_tracks, SetTrack, foreign_key: :rec_set_id

    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(rec_set, attrs) do
    rec_set
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end
end
