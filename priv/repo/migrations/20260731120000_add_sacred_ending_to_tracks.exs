defmodule Beatgrid.Repo.Migrations.AddSacredEndingToTracks do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      # Curadoria humana: esta música tem um FINAL clássico que o salão espera
      # (o passo especial) — nenhum algoritmo pode cortá-la cedo.
      add :sacred_ending, :boolean, default: false, null: false
    end
  end
end
