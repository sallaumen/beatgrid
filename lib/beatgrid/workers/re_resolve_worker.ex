defmodule Beatgrid.Workers.ReResolveWorker do
  @moduledoc """
  Re-resolves ONE audit-flagged rename suggestion against Soundcharts (spends
  quota): rejects the suspect suggestion and, on a fresh match, re-proposes a
  rename from it. Runs in the background so it survives navigation and shows in
  `/jobs`; broadcasts `{:re_resolve_done, …}` on the re-evaluation topic so the
  Central de Revisão can react. Queued on `:soundcharts` (local_limit 1) so it
  serializes with the other quota-spending workers.

  Triggered only by an explicit user click — never auto-enqueued.
  """
  # Unique per suggestion while in flight — a double-click must not spend
  # Soundcharts quota twice for the same suggestion.
  use Oban.Worker,
    queue: :soundcharts,
    max_attempts: 3,
    unique: [
      period: 3600,
      keys: [:suggestion_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Beatgrid.Library.NameSync
  alias Beatgrid.Review

  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(suggestion_id), do: %{suggestion_id: suggestion_id} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"suggestion_id" => id}}) do
    case NameSync.get(id) do
      nil ->
        {:cancel, :not_found}

      suggestion ->
        outcome = re_resolve_outcome(suggestion)
        Review.broadcast_re_resolve(%{suggestion_id: id, outcome: outcome})
        if outcome == :budget_exhausted, do: {:snooze, 3600}, else: :ok
    end
  end

  defp re_resolve_outcome(suggestion) do
    case Review.re_resolve(suggestion) do
      {:ok, outcome} -> outcome
      {:error, :budget_exhausted} -> :budget_exhausted
      {:error, _reason} -> :error
    end
  end
end
