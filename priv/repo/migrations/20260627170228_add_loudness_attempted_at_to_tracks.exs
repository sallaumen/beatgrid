defmodule Beatgrid.Repo.Migrations.AddLoudnessAttemptedAtToTracks do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :loudness_attempted_at, :utc_datetime
    end
  end
end
