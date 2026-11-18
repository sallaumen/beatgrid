defmodule Beatgrid.Sets.RecSet do
  @moduledoc "A named, ordered harmonic set (a DJ set / crate the user is building)."
  use Ecto.Schema

  import Ecto.Changeset

  alias Beatgrid.Sets.SetTrack

  @type t :: %__MODULE__{}
  @max_name_length 255

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "rec_sets" do
    field :name, :string
    field :target_style, :string

    has_many :set_tracks, SetTrack, foreign_key: :rec_set_id

    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(rec_set, attrs) do
    rec_set
    |> cast(attrs, [:name, :target_style])
    |> validate_required([:name])
    |> validate_length(:name, max: @max_name_length, count: :codepoints)
  end

  @doc "Adds the copy suffix within the database's character limit."
  @spec copy_name(String.t()) :: String.t()
  def copy_name(name) do
    suffix = " (cópia)"
    prefix = name |> String.codepoints() |> Enum.take(@max_name_length - String.length(suffix))
    Enum.join(prefix) <> suffix
  end
end
