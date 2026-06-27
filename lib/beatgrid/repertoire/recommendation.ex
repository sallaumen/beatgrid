defmodule Beatgrid.Repertoire.Recommendation do
  @moduledoc "A persisted AI song suggestion — a folder gap or a per-track match."
  use Ecto.Schema
  import Ecto.Changeset
  alias Beatgrid.Library.Track

  @type t :: %__MODULE__{}
  @sources ~w(gaps match)a
  @statuses ~w(new dismissed imported)a

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "recommendations" do
    field :artist, :string
    field :song, :string
    field :reason, :string
    field :youtube_query, :string
    field :genre_folder, :string
    field :source, Ecto.Enum, values: @sources
    field :status, Ecto.Enum, values: @statuses, default: :new
    field :batch_id, Uniq.UUID
    belongs_to :track, Track, foreign_key: :track_id
    timestamps()
  end

  @castable ~w(artist song reason youtube_query genre_folder source status batch_id track_id)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(rec, attrs) do
    rec
    |> cast(attrs, @castable)
    |> validate_required([:artist, :song, :source])
    |> validate_scope()
    |> assoc_constraint(:track)
  end

  defp validate_scope(cs) do
    if get_field(cs, :genre_folder) || get_field(cs, :track_id) do
      cs
    else
      add_error(cs, :genre_folder, "a folder or track scope is required")
    end
  end

  def statuses, do: @statuses
  def sources, do: @sources
end
