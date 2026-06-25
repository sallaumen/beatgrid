defmodule Beatgrid.Organization.MoveSuggestion do
  @moduledoc """
  A proposed move of a track into a genre folder. Nothing moves on disk until a
  suggestion is applied; applied suggestions are reversible (the move history).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Beatgrid.Library.Track

  @type t :: %__MODULE__{}

  @sources ~w(rule claude dedup manual)a
  @statuses ~w(pending approved rejected applied failed undone)a

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "move_suggestions" do
    field :from_rel_path, :string
    field :to_genre_folder, :string
    field :reason, :string
    field :source, Ecto.Enum, values: @sources
    field :confidence, :float
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :batch_id, Uniq.UUID
    field :applied_at, :utc_datetime
    field :error, :string

    belongs_to :track, Track, foreign_key: :track_id

    timestamps()
  end

  @castable ~w(track_id from_rel_path to_genre_folder reason source confidence
               status batch_id applied_at error)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(suggestion, attrs) do
    suggestion
    |> cast(attrs, @castable)
    |> validate_required([:track_id, :from_rel_path, :to_genre_folder, :source])
    |> assoc_constraint(:track)
  end

  @doc "Allowed `status` values."
  def statuses, do: @statuses
end
