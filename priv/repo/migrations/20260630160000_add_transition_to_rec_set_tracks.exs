defmodule Beatgrid.Repo.Migrations.AddTransitionToRecSetTracks do
  use Ecto.Migration

  # The transition INTO an entry (from the previous track) — a JSON map
  # %{"enabled","type","from_ms","to_ms"}. nil = not connected (plain sequential play).
  def change do
    alter table(:rec_set_tracks) do
      add :transition, :map
    end
  end
end
