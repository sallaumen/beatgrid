defmodule Beatgrid.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:settings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :key, :string, null: false
      # The value is wrapped as %{"v" => term} so any JSON scalar round-trips.
      add :value, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:settings, [:key])
  end
end
