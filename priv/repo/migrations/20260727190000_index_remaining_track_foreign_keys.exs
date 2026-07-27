defmodule Beatgrid.Repo.Migrations.IndexRemainingTrackForeignKeys do
  use Ecto.Migration

  # Deleting a track cascades into rec_set_tracks and nilifies duplicate_groups/
  # mix_segments; without these indexes every deletion scans those tables.
  def change do
    create index(:rec_set_tracks, [:track_id])
    create index(:duplicate_groups, [:keeper_track_id])
    create index(:mix_segments, [:matched_track_id])
  end
end
