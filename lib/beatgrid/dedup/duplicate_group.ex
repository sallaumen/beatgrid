defmodule Beatgrid.Dedup.DuplicateGroup do
  @moduledoc "A set of tracks detected as duplicates of each other."
  use Ecto.Schema

  import Ecto.Changeset

  alias Beatgrid.Dedup.DuplicateMember
  alias Beatgrid.Library.Track

  @type t :: %__MODULE__{}

  @match_types ~w(exact_hash fuzzy_meta)a
  @statuses ~w(pending resolved)a

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "duplicate_groups" do
    field :match_type, Ecto.Enum, values: @match_types
    field :signature, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending

    belongs_to :keeper_track, Track, foreign_key: :keeper_track_id
    has_many :members, DuplicateMember, foreign_key: :group_id

    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(group, attrs) do
    group
    |> cast(attrs, [:match_type, :signature, :status, :keeper_track_id])
    |> validate_required([:match_type, :signature])
    |> assoc_constraint(:keeper_track)
  end
end
