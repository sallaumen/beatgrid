defmodule Beatgrid.Workers.DedupWorker do
  @moduledoc "Recomputes duplicate groups in the background."
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 30]

  alias Beatgrid.Dedup

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, _summary} = Dedup.detect()
    :ok
  end

  @spec enqueue() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue, do: %{} |> new() |> Oban.insert()
end
