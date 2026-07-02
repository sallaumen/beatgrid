defmodule Beatgrid.Workers.ImportWorker do
  @moduledoc """
  Commits a reviewed folder/file import in the background: copies the chosen files
  into `_Inbox` and creates tracks with the reviewed (possibly edited) artist/title,
  broadcasting `{:import_progress, …}` so the Library screen shows live progress.

  Runs on the `:scan` queue (the FS-heavy queue, concurrency 2). `max_attempts: 1`
  — a partial copy shouldn't silently re-run; re-running would be safe anyway
  (already-copied files dedup-skip), but the user retries from `/jobs` instead.

  When `"resolve_soundcharts"` is set (opt-in checkbox), it chains the full
  Soundcharts enrich over the freshly-imported pending tracks via `EnrichWorker`
  (`scope: "pending"`) — the only quota-spending step, and only ever on this
  explicit opt-in.
  """
  use Oban.Worker, queue: :scan, max_attempts: 1

  alias Beatgrid.Library
  alias Beatgrid.Workers.EnrichWorker

  @spec enqueue([map()], Ecto.UUID.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(items, batch_id, opts \\ []) do
    %{
      "items" => items,
      "batch_id" => batch_id,
      "resolve_soundcharts" => Keyword.get(opts, :resolve_soundcharts, false)
    }
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"items" => items, "batch_id" => bid} = args}) do
    summary = Library.import_files(items, bid)

    if args["resolve_soundcharts"] do
      {:ok, _job} = EnrichWorker.enqueue("pending")
    end

    {:ok, summary}
  end
end
