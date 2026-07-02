defmodule Beatgrid.Workers.ReviewApplyWorker do
  @moduledoc """
  Applies the selected review suggestions to disk in the background, so the work
  is durable (survives a closed tab, shows in `/jobs`) instead of dying with the
  LiveView. Broadcasts `{:review_applied, result}` on the review topic when done,
  which unblocks the Central de Revisão and shows the undo toast.

  `max_attempts: 1` — the apply reports per-item applied/failed counts and never
  aborts on one failure, so an automatic whole-batch retry would only skew the
  tally; the user re-applies what failed from the screen.
  """
  use Oban.Worker,
    queue: :scan,
    max_attempts: 1,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  alias Beatgrid.Review

  @spec enqueue([Ecto.UUID.t()]) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(ids) when is_list(ids), do: %{ids: ids} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ids" => ids}}) do
    {:ok, result} = Review.apply_selected(ids)
    Review.broadcast_applied(result)
    :ok
  end
end
