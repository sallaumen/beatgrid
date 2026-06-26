defmodule Beatgrid.Workers.ExpandWorker do
  @moduledoc """
  Expands a submitted YouTube URL (single video or playlist) into one
  `DownloadWorker` job per video, carrying the source playlist URL for provenance.
  """
  use Oban.Worker, queue: :youtube, max_attempts: 3

  alias Beatgrid.YouTube

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url}}) do
    case YouTube.expand_and_enqueue(url) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
