defmodule Beatgrid.Repo.Migrations.AddReviewQualityFields do
  use Ecto.Migration

  def change do
    alter table(:rename_suggestions) do
      add :rationale, :text
    end

    alter table(:tracks) do
      add :sc_art_trusted, :boolean, default: true, null: false
    end
  end
end
