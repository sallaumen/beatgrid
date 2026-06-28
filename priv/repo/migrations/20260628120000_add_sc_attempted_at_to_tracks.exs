defmodule Beatgrid.Repo.Migrations.AddScAttemptedAtToTracks do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :sc_attempted_at, :utc_datetime
    end
  end
end
