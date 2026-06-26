defmodule Beatgrid.Library.RenameSuggestion do
  @moduledoc """
  A proposed rename of a track's file to its canonical `"Artist - Title"` name
  (derived from the linked Soundcharts song). High-confidence proposals are
  auto-applied; the rest wait for review. Applied renames are reversible.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Beatgrid.Library.Track

  @type t :: %__MODULE__{}

  @statuses ~w(pending approved rejected applied failed undone)a

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "rename_suggestions" do
    field :from_rel_path, :string
    field :from_filename, :string
    field :to_filename, :string
    field :confidence, Ecto.Enum, values: [:high, :medium, :low]
    field :reason, :string
    field :rationale, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :batch_id, Uniq.UUID
    field :applied_at, :utc_datetime
    field :error, :string

    belongs_to :track, Track, foreign_key: :track_id

    timestamps()
  end

  @castable ~w(track_id from_rel_path from_filename to_filename confidence reason rationale
               status batch_id applied_at error)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(suggestion, attrs) do
    suggestion
    |> cast(attrs, @castable)
    |> validate_required([:track_id, :from_rel_path, :from_filename, :to_filename])
    |> assoc_constraint(:track)
  end

  @doc "Allowed `status` values."
  def statuses, do: @statuses
end
