defmodule Beatgrid.Repo.Migrations.AddAccountToApiCalls do
  use Ecto.Migration

  # Which Soundcharts account a call was billed to, so the budget guard can track
  # each account's quota independently and fail over when one runs out. Existing
  # rows belong to the first account.
  def change do
    alter table(:api_calls) do
      add :account, :string, null: false, default: "1"
    end

    create index(:api_calls, [:account, :success])
  end
end
