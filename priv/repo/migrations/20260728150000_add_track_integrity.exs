defmodule Beatgrid.Repo.Migrations.AddTrackIntegrity do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :integrity_status, :string, null: false, default: "unchecked"
      add :integrity_error, :string
      add :integrity_checked_at, :utc_datetime
    end
  end
end
