defmodule Beatgrid.Workers.UndoBatchWorker do
  @moduledoc """
  Reverts one operations batch (renames, moves, genre tags) in the background, so
  the undo is durable and visible in `/jobs`. Broadcasts `{:batch_undone, result}`
  on the review topic when done.

  `max_attempts: 1` — the undo reports per-item undone/failed counts, skips
  already-undone operations, and never aborts on one failure; the user retries
  explicitly instead of Oban re-running the whole batch.
  """
  use Oban.Worker,
    queue: :scan,
    max_attempts: 1,
    unique: [
      period: 60,
      keys: [:batch_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Beatgrid.Operations
  alias Beatgrid.Review

  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(batch_id), do: %{batch_id: batch_id} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_id" => batch_id}}) do
    {:ok, result} = Operations.undo_batch(batch_id)
    Review.broadcast_undone(result)
    :ok
  end
end
