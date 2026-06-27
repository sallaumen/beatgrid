defmodule Beatgrid.Repo.Migrations.AddManualEditsToTracks do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :bpm_manual, :float
      add :camelot_manual, :string
      add :manual_fields, {:array, :string}, default: [], null: false
    end
  end
end
