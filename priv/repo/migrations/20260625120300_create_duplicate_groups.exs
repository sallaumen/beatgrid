defmodule Beatgrid.Repo.Migrations.CreateDuplicateGroups do
  use Ecto.Migration

  def change do
    create table(:duplicate_groups, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :match_type, :string, null: false
      add :signature, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :keeper_track_id, references(:tracks, type: :uuid, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create table(:duplicate_members, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false

      add :group_id, references(:duplicate_groups, type: :uuid, on_delete: :delete_all),
        null: false

      add :track_id, references(:tracks, type: :uuid, on_delete: :delete_all), null: false
      add :is_keeper, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:duplicate_groups, [:status])
    create_if_not_exists index(:duplicate_members, [:group_id])
    create_if_not_exists index(:duplicate_members, [:track_id])
    create_if_not_exists unique_index(:duplicate_members, [:group_id, :track_id])
  end
end
