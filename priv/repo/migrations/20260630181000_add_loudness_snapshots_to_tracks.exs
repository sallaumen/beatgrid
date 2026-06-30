defmodule Beatgrid.Repo.Migrations.AddLoudnessSnapshotsToTracks do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :original_loudness_lufs, :float
      add :original_true_peak_dbtp, :float
      add :original_loudness_measured_at, :utc_datetime
      add :loudness_measurement_origin, :string
    end
  end
end
