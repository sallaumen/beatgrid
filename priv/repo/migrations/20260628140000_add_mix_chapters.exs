defmodule Beatgrid.Repo.Migrations.AddMixChapters do
  use Ecto.Migration

  def change do
    alter table(:mixes) do
      add :chapters, {:array, :map}, null: false, default: []
      add :chapters_role, :string, null: false, default: "tracks"
    end
  end
end
