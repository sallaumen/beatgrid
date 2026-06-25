defmodule Beatgrid.Repo.Migrations.CreateGenreFolders do
  use Ecto.Migration

  def change do
    create table(:genre_folders, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :key, :string, null: false
      add :display_name, :string, null: false
      add :dir_name, :string, null: false
      add :description, :text
      add :sort_order, :integer, null: false, default: 0
      add :color, :string

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:genre_folders, [:key])
  end
end
