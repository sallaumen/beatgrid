defmodule Beatgrid.Repo.Migrations.CreateMixDjParts do
  use Ecto.Migration

  def change do
    create table(:mix_dj_parts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :mix_id, references(:mixes, type: :uuid, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :start_ms, :integer, null: false
      add :end_ms, :integer, null: false
      add :dj_name, :string
      add :source, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:mix_dj_parts, [:mix_id])
  end
end
