defmodule Beatgrid.Soundcharts.Artist do
  @moduledoc "Cached Soundcharts artist metadata (1 row per Soundcharts UUID)."
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "soundcharts_artists" do
    field :sc_uuid, :string
    field :name, :string
    field :country_code, :string
    field :genres, {:array, :string}, default: []
    field :career_stage, :string
    field :raw, :map, default: %{}
    field :fetched_at, :utc_datetime

    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(artist, attrs) do
    artist
    |> cast(attrs, ~w(sc_uuid name country_code genres career_stage raw fetched_at)a)
    |> validate_required([:sc_uuid])
    |> unique_constraint(:sc_uuid)
  end
end
