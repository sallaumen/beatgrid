defmodule Beatgrid.Workers.DownloadWorker do
  @moduledoc """
  Downloads one YouTube URL (video or playlist) into `_Inbox` and ingests the
  tracks, broadcasting a progress tick. Retries on transient failures.
  """
  use Oban.Worker, queue: :youtube, max_attempts: 3

  alias Beatgrid.YouTube

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url}}) do
    case YouTube.download_and_ingest(url) do
      {:ok, _count} ->
        YouTube.broadcast_tick()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
