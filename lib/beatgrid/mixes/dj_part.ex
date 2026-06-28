defmodule Beatgrid.Mixes.DjPart do
  @moduledoc "A contiguous span of a mix attributed to one DJ (overlay over segments)."
  use Ecto.Schema
  import Ecto.Changeset
  alias Beatgrid.Mixes.Mix

  @type t :: %__MODULE__{}
  @sources [:manual, :chapter, :image, :audio]

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "mix_dj_parts" do
    field :position, :integer
    field :start_ms, :integer
    field :end_ms, :integer
    field :dj_name, :string
    field :source, Ecto.Enum, values: @sources
    belongs_to :mix, Mix
    timestamps()
  end

  @fields ~w(mix_id position start_ms end_ms dj_name source)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(part, attrs) do
    part
    |> cast(attrs, @fields)
    |> validate_required([:position, :start_ms, :end_ms, :source])
  end
end
