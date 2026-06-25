defmodule Beatgrid.Repo.Migrations.CreateRecSets do
  use Ecto.Migration

  def change do
    create table(:rec_sets, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:rec_set_tracks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :rec_set_id, references(:rec_sets, type: :uuid, on_delete: :delete_all), null: false
      add :track_id, references(:tracks, type: :uuid, on_delete: :delete_all), null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rec_set_tracks, [:rec_set_id])
    create unique_index(:rec_set_tracks, [:rec_set_id, :track_id])
  end
end
