defmodule Beatgrid.Jobs do
  @moduledoc """
  UI-facing read/control of background jobs — a thin wrapper over Oban's job table.
  The state shown is Oban's own (`available`/`executing`/`completed`/`retryable`/
  `discarded`/`cancelled`), so there is no parallel state machine to drift.
  """
  import Ecto.Query

  alias Beatgrid.Repo

  @doc "Most recent jobs (newest first), optionally filtered by `:states`."
  @spec list_recent(keyword()) :: [Oban.Job.t()]
  def list_recent(opts \\ []) do
    limit = opts[:limit] || 100

    Oban.Job
    |> order_by([j], desc: j.id)
    |> limit(^limit)
    |> maybe_filter_states(opts[:states])
    |> Repo.all()
  end

  defp maybe_filter_states(query, nil), do: query
  defp maybe_filter_states(query, states), do: where(query, [j], j.state in ^states)

  @doc "Re-run a failed/cancelled job."
  @spec retry(integer()) :: :ok
  def retry(id), do: Oban.retry_job(id)

  @doc "Cancel a queued/executing job."
  @spec cancel(integer()) :: :ok
  def cancel(id), do: Oban.cancel_job(id)
end
