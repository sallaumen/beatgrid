defmodule Beatgrid.Workers.DbBackupWorker do
  @moduledoc """
  Dumps the database to `_Backups/DB` — daily via the Oban cron entry, or on
  demand from the Painel. Unique per hour so cron + button never double-dump.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 2,
    unique: [period: 3600]

  alias Beatgrid.Backup

  @spec enqueue() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue, do: %{} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(_job) do
    case Backup.dump() do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
