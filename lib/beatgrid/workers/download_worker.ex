defmodule Beatgrid.Workers.DownloadWorker do
  @moduledoc """
  Downloads one YouTube video into `_Inbox` and ingests the track (with source
  provenance), broadcasting a progress tick. Deduped per video URL while a job for
  it is in flight.

  Retry policy is YouTube-aware: a 429 (rate limit) is retried with a long backoff
  even when yt-dlp *also* reports "video unavailable" (the unavailability is the
  rate limit talking). A genuine "unavailable" with no 429 is permanent, so the
  job is cancelled rather than burning all its attempts.
  """
  use Oban.Worker,
    queue: :youtube,
    max_attempts: 10,
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
        cond do
          rate_limited?(reason) -> {:error, reason}
          unavailable?(reason) -> {:cancel, reason}
          true -> {:error, reason}
        end
    end
  end

  # YouTube rate-limits hard; after a 429 wait at least ~30s and back off further
  # on repeats. Anything else uses Oban's default exponential backoff.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt} = job) do
    if last_error_rate_limited?(job), do: min(30 * attempt, 300), else: super(job)
  end

  defp rate_limited?({:yt_dlp_exit, _code, out}) when is_binary(out),
    do: out =~ "429" or out =~ "Too Many Requests"

  defp rate_limited?(_reason), do: false

  defp unavailable?({:yt_dlp_exit, _code, out}) when is_binary(out),
    do: out =~ "Video unavailable" or out =~ "not available"

  defp unavailable?(_reason), do: false

  defp last_error_rate_limited?(%Oban.Job{errors: errors}) do
    case List.last(errors || []) do
      %{"error" => message} when is_binary(message) ->
        message =~ "429" or message =~ "Too Many Requests"

      _ ->
        false
    end
  end
end
