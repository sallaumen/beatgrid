defmodule Beatgrid.Workers.ExpandWorker do
  @moduledoc """
  Expands a submitted YouTube URL (single video or playlist) into one
  `DownloadWorker` job per video, carrying the source playlist URL for provenance.
  """
  # Unique per URL while in flight, so pasting the same playlist twice (or a
  # double-click) doesn't fan out duplicate downloads.
  use Oban.Worker,
    queue: :youtube,
    max_attempts: 3,
    unique: [
      period: 3600,
      keys: [:url],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Beatgrid.YouTube

  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(url), do: %{url: url} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url}}) do
    case YouTube.expand_and_enqueue(url) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
