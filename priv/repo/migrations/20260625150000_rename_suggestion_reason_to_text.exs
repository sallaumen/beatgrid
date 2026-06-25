defmodule Beatgrid.Repo.Migrations.RenameSuggestionReasonToText do
  use Ecto.Migration

  def change do
    alter table(:rename_suggestions) do
      modify :reason, :text, from: :string
    end
  end
end
