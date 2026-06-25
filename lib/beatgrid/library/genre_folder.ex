defmodule Beatgrid.Library.GenreFolder do
  @moduledoc """
  A target genre folder on disk (e.g. "Forró Roots").

  `description` is the user's classification rubric for the folder and is fed to
  the AI classifier. `key` is the stable identifier; `dir_name` is the on-disk
  folder name under the library root.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "genre_folders" do
    field :key, :string
    field :display_name, :string
    field :dir_name, :string
    field :description, :string
    field :sort_order, :integer, default: 0
    field :color, :string

    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [:key, :display_name, :dir_name, :description, :sort_order, :color])
    |> validate_required([:key, :display_name, :dir_name])
    |> unique_constraint(:key)
  end
end
