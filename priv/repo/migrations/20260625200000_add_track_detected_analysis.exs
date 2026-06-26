defmodule Beatgrid.Repo.Migrations.AddTrackDetectedAnalysis do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :bpm_detected, :float
      add :camelot_detected, :string
      add :analyzed_at, :utc_datetime
    end
  end
end
