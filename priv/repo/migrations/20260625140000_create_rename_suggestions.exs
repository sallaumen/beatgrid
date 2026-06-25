defmodule Beatgrid.Repo.Migrations.CreateRenameSuggestions do
  use Ecto.Migration

  def change do
    create table(:rename_suggestions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :track_id, references(:tracks, type: :uuid, on_delete: :delete_all), null: false
      add :from_rel_path, :string, null: false
      add :from_filename, :string, null: false
      add :to_filename, :string, null: false
      add :confidence, :string
      add :reason, :string
      add :status, :string, null: false, default: "pending"
      add :batch_id, :uuid
      add :applied_at, :utc_datetime
      add :error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:rename_suggestions, [:track_id])
    create index(:rename_suggestions, [:status])
  end
end
