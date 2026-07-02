defmodule Beatgrid.Settings.Setting do
  @moduledoc "One runtime setting override: a key and its JSON-wrapped value."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @timestamps_opts [type: :utc_datetime]

  schema "settings" do
    field :key, :string
    # Wrapped as %{"v" => term} so any JSON scalar (number/string/bool) round-trips.
    field :value, :map

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
    |> unique_constraint(:key)
  end
end
