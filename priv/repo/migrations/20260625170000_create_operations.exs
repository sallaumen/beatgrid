defmodule Beatgrid.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    create table(:operations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :track_id, references(:tracks, type: :uuid, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :from, :string
      add :to, :string
      add :status, :string, null: false, default: "applied"
      add :batch_id, :uuid, null: false
      add :suggestion_id, :uuid
      add :error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:operations, [:batch_id])
    create index(:operations, [:track_id])
    create index(:operations, [:status])
  end
end
