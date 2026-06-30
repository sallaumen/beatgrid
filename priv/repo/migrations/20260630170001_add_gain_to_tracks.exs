defmodule Beatgrid.Repo.Migrations.AddGainToTracks do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :gain_applied_db, :float
      add :gain_applied_at, :utc_datetime
    end
  end
end
