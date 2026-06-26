defmodule Beatgrid.Repo.Migrations.AddRecSetScoringFields do
  use Ecto.Migration

  def change do
    alter table(:rec_sets) do
      add :target_style, :string
    end

    alter table(:rec_set_tracks) do
      add :role, :string
    end
  end
end
