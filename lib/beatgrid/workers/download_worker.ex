defmodule Beatgrid.Workers.DownloadWorker do
  @moduledoc """
  Downloads one YouTube video into `_Inbox` and ingests the track (with source
  provenance), broadcasting a progress tick. Retries on transient failures;
  deduped per video URL while a job for it is in flight.
  """
  use Oban.Worker,
    queue: :youtube,
    max_attempts: 3,
    unique: [
      period: 3600,
      keys: [:url],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Beatgrid.YouTube

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url} = args}) do
    case YouTube.download_and_ingest(url, args["playlist_url"]) do
      {:ok, _count} ->
        YouTube.broadcast_tick()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
