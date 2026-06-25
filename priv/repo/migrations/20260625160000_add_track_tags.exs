defmodule Beatgrid.Repo.Migrations.AddTrackTags do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :tags, {:array, :string}, default: []
    end
  end
end
