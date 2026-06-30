defmodule Beatgrid.Repo.Migrations.AddAuddAttemptedAtToSegments do
  use Ecto.Migration

  def change do
    alter table(:mix_segments) do
      add :audd_attempted_at, :utc_datetime
    end
  end
end
