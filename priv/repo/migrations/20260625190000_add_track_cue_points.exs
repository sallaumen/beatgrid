defmodule Beatgrid.Repo.Migrations.AddTrackCuePoints do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :cue_points, {:array, :map}, default: []
    end
  end
end
