defmodule Beatgrid.Dedup.DuplicateMember do
  @moduledoc "Membership of a track in a duplicate group; `is_keeper` marks the one to keep."
  use Ecto.Schema

  import Ecto.Changeset

  alias Beatgrid.Dedup.DuplicateGroup
  alias Beatgrid.Library.Track

  @type t :: %__MODULE__{}

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "duplicate_members" do
    field :is_keeper, :boolean, default: false

    belongs_to :group, DuplicateGroup, foreign_key: :group_id
    belongs_to :track, Track, foreign_key: :track_id

    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:group_id, :track_id, :is_keeper])
    |> validate_required([:group_id, :track_id])
    |> assoc_constraint(:group)
    |> assoc_constraint(:track)
    |> unique_constraint([:group_id, :track_id])
  end
end
