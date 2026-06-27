defmodule Beatgrid.Repo.Migrations.AddLoudnessToTracks do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :loudness_lufs, :float
      add :true_peak_dbtp, :float
    end
  end
end
