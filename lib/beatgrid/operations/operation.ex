defmodule Beatgrid.Operations.Operation do
  @moduledoc """
  One disk mutation applied through the review surface (a rename, a move, or an
  ID3 genre write). Operations are grouped by `batch_id` (one "Aplicar no disco"
  action) and link back to the suggestion that produced them, so `undo_batch/1`
  can revert the whole batch by delegating to the owning context.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Beatgrid.Library.Track

  @type t :: %__MODULE__{}

  @kinds ~w(rename move tag quarantine gain)a
  @statuses ~w(applied undone failed)a

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "operations" do
    field :kind, Ecto.Enum, values: @kinds
    field :from, :string
    field :to, :string
    field :status, Ecto.Enum, values: @statuses, default: :applied
    field :batch_id, Uniq.UUID
    field :suggestion_id, Uniq.UUID
    field :error, :string

    belongs_to :track, Track, foreign_key: :track_id

    timestamps()
  end

  @castable ~w(track_id kind from to status batch_id suggestion_id error)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(operation, attrs) do
    operation
    |> cast(attrs, @castable)
    |> validate_required([:track_id, :kind, :batch_id])
    |> assoc_constraint(:track)
  end

  @doc "Allowed `kind` values."
  def kinds, do: @kinds

  @doc "Allowed `status` values."
  def statuses, do: @statuses
end
