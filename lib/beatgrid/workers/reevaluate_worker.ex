defmodule Beatgrid.Workers.ReevaluateWorker do
  @moduledoc """
  Re-evaluates a scope of rename suggestions with the AI verifier, in chunks,
  broadcasting `{:reevaluate_progress, …}` after each chunk so the LiveView can show
  live progress. Survives navigation (runs in Oban, not the LiveView). Quota-free.
  """
  use Oban.Worker, queue: :ai, max_attempts: 1

  alias Beatgrid.Review

  @batch 15

  @doc "Enqueues a re-evaluation for the given scope args, stamping a fresh batch id."
  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(scope_args) when is_map(scope_args) do
    scope_args
    |> Map.put("batch_id", Uniq.UUID.uuid7())
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_id" => batch_id} = args}) do
    suggestions = Review.suggestions_for_scope(args)
    total = length(suggestions)
    Review.broadcast_progress(%{batch_id: batch_id, status: :running, done: 0, total: total})

    {done, updated} =
      suggestions
      |> Enum.chunk_every(@batch)
      |> Enum.reduce({0, 0}, fn chunk, {done, updated} ->
        u = Review.reevaluate_chunk(chunk)
        done = done + length(chunk)

        Review.broadcast_progress(%{
          batch_id: batch_id,
          status: :running,
          done: done,
          total: total
        })

        {done, updated + u}
      end)

    Review.broadcast_progress(%{
      batch_id: batch_id,
      status: :done,
      done: done,
      total: total,
      updated: updated
    })

    :ok
  end
end
