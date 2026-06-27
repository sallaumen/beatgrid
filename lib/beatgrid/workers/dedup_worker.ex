defmodule Beatgrid.Workers.DedupWorker do
  @moduledoc "Recomputes duplicate groups in the background."
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 30]

  alias Beatgrid.Dedup

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    batch_id = args["batch_id"]
    Dedup.broadcast_progress(%{status: :running, batch_id: batch_id})
    {:ok, %{exact: exact, fuzzy: fuzzy}} = Dedup.detect()
    Dedup.broadcast_progress(%{status: :done, batch_id: batch_id, groups: exact + fuzzy})
    :ok
  end

  @spec enqueue() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue, do: %{} |> new() |> Oban.insert()

  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(batch_id), do: %{batch_id: batch_id} |> new() |> Oban.insert()
end
