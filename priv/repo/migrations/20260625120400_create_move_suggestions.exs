defmodule Beatgrid.Repo.Migrations.CreateMoveSuggestions do
  use Ecto.Migration

  def change do
    create table(:move_suggestions, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :track_id, references(:tracks, type: :uuid, on_delete: :delete_all), null: false
      add :from_rel_path, :string, null: false
      add :to_genre_folder, :string, null: false
      add :reason, :text
      add :source, :string, null: false
      add :confidence, :float
      add :status, :string, null: false, default: "pending"
      add :batch_id, :uuid
      add :applied_at, :utc_datetime
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:move_suggestions, [:status])
    create_if_not_exists index(:move_suggestions, [:batch_id])
    create_if_not_exists index(:move_suggestions, [:track_id])
  end
end
