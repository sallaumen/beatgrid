defmodule Beatgrid.Jobs do
  @moduledoc """
  UI-facing read/control of background jobs — a thin wrapper over Oban's job table.
  The state shown is Oban's own (`available`/`executing`/`completed`/`retryable`/
  `discarded`/`cancelled`), so there is no parallel state machine to drift.
  """
  import Ecto.Query

  alias Beatgrid.Repo

  # The two terminal give-up states — what "failed" means across the UI.
  @failed_states ["discarded", "cancelled"]

  @doc "Most recent jobs (newest first), optionally filtered by `:states` and `:worker` (short name)."
  @spec list_recent(keyword()) :: [Oban.Job.t()]
  def list_recent(opts \\ []) do
    limit = opts[:limit] || 100

    Oban.Job
    |> order_by([j], desc: j.id)
    |> limit(^limit)
    |> maybe_filter_states(opts[:states])
    |> maybe_filter_worker(opts[:worker])
    |> Repo.all()
  end

  defp maybe_filter_states(query, nil), do: query
  defp maybe_filter_states(query, states), do: where(query, [j], j.state in ^states)

  defp maybe_filter_worker(query, nil), do: query

  defp maybe_filter_worker(query, worker),
    do: where(query, [j], j.worker == ^"Beatgrid.Workers.#{worker}")

  @doc "Re-queues every failed (discarded/cancelled) job, optionally of one `worker`. Returns the count."
  @spec retry_failed(String.t() | nil) :: non_neg_integer()
  def retry_failed(worker \\ nil) do
    {:ok, count} = Oban.retry_all_jobs(failed_query(worker))
    count
  end

  @doc """
  Deletes every failed (discarded/cancelled) job row, optionally of one `worker` —
  the permanent "limpar" for a failure list. Only terminal rows are touched; the
  jobs table is a log here, so deleting rows discards no pending work.
  """
  @spec clear_failed(String.t() | nil) :: non_neg_integer()
  def clear_failed(worker \\ nil) do
    {count, _} = Repo.delete_all(failed_query(worker))
    count
  end

  defp failed_query(worker) do
    Oban.Job
    |> where([j], j.state in ^@failed_states)
    |> maybe_filter_worker(worker)
  end

  @doc "How many jobs of `worker` gave up (discarded or cancelled)."
  @spec failed_count(module()) :: non_neg_integer()
  def failed_count(worker) do
    name = worker |> Module.split() |> Enum.join(".")

    Oban.Job
    |> where([j], j.worker == ^name and j.state in ["discarded", "cancelled"])
    |> Repo.aggregate(:count, :id)
  end

  @doc "Re-run a failed/cancelled job."
  @spec retry(integer()) :: :ok
  def retry(id), do: Oban.retry_job(id)

  @doc "Cancel a queued/executing job."
  @spec cancel(integer()) :: :ok
  def cancel(id), do: Oban.cancel_job(id)
end
