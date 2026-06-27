defmodule Beatgrid.Workers.EnrichWorker do
  @moduledoc """
  Enriches downloaded tracks against Soundcharts in the background, broadcasting
  `{:enrich_progress, …}` per item so the LiveView shows live progress. Runs on
  the `:soundcharts` queue (concurrency 1) so it serializes the quota-spending with
  the other Soundcharts workers. Two scopes:

    * `"track"`  — one track, enqueued by the per-track "Atualizar metadados" button.
    * `"pending"` — every downloaded-but-unfiled track, enqueued by the dashboard.

  Soundcharts is button-triggered: this worker is only ever *enqueued by a UI
  click*, never auto. Budget exhaustion returns `:ok` (so Oban doesn't retry
  pointlessly) and carries `budget_exhausted: true` on the final broadcast;
  transient crashes propagate and Oban retries up to 3×.
  """
  use Oban.Worker, queue: :soundcharts, max_attempts: 3

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Organization.ClassificationAI
  alias Beatgrid.YouTube

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scope" => "track", "id" => id, "batch_id" => bid}}) do
    YouTube.broadcast_enrich(%{
      batch_id: bid,
      scope: "track",
      id: id,
      status: :running,
      done: 0,
      total: 1
    })

    {done, resolved, budget} = enrich_ids([id], bid, "track", id)

    YouTube.broadcast_enrich(%{
      batch_id: bid,
      scope: "track",
      id: id,
      status: :done,
      done: done,
      total: 1,
      resolved: resolved,
      budget_exhausted: budget
    })

    :ok
  end

  def perform(%Oban.Job{args: %{"scope" => "pending", "batch_id" => bid}}) do
    ids = YouTube.pending_ids()
    total = length(ids)

    YouTube.broadcast_enrich(%{
      batch_id: bid,
      scope: "pending",
      id: nil,
      status: :running,
      done: 0,
      total: total
    })

    # Batch AI title-refinement (no quota) before the per-track resolution loop.
    YouTube.refine_titles(ids)
    {done, resolved, budget} = enrich_ids(ids, bid, "pending", nil)

    YouTube.broadcast_enrich(%{
      batch_id: bid,
      scope: "pending",
      id: nil,
      status: :done,
      done: done,
      total: total,
      resolved: resolved,
      budget_exhausted: budget
    })

    :ok
  end

  # Iterate, broadcasting per item; stop early on budget exhaustion; one batched
  # reclassify at the end over just the tracks we actually processed.
  defp enrich_ids(ids, bid, scope, single_id) do
    total = length(ids)

    ctx = %{batch_id: bid, scope: scope, id: single_id, total: total}

    {done, resolved, budget, processed} =
      Enum.reduce_while(ids, {0, 0, false, []}, &enrich_step(&1, &2, ctx))

    if processed != [],
      do: ClassificationAI.reclassify(tracks: Enum.map(processed, &Tracks.get/1))

    {done, resolved, budget}
  end

  defp enrich_step(id, {done, res, _b, acc}, ctx) do
    case YouTube.resolve_track_enrich(id) do
      :budget_exhausted ->
        {:halt, {done, res, true, acc}}

      outcome ->
        done = done + 1
        res = res + if outcome == :resolved, do: 1, else: 0

        YouTube.broadcast_enrich(Map.merge(ctx, %{status: :running, done: done, resolved: res}))

        {:cont, {done, res, false, [id | acc]}}
    end
  end
end
