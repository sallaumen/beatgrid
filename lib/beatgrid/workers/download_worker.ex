defmodule Beatgrid.Workers.DownloadWorker do
  @moduledoc """
  Downloads one YouTube video into `_Inbox` and ingests the track (with source
  provenance), broadcasting a progress tick. Deduped per video URL while a job for
  it is in flight.

  Retry policy is YouTube-aware, branching on the `Beatgrid.Error` code the
  yt-dlp adapter classifies (`Beatgrid.YtDlpError`): `:rate_limited` retries
  with a long backoff — even when yt-dlp *also* reported "video unavailable"
  (the unavailability is the rate limit talking) — while `:video_unavailable`
  is permanent, so the job is cancelled rather than burning all its attempts.
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
  alias Beatgrid.YouTube.Link

  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(url, opts \\ []) do
    args = %{
      url: url,
      video_id: opts[:video_id],
      recommendation_id: opts[:recommendation_id],
      title: opts[:title],
      playlist_url: opts[:playlist_url],
      playlist_index: opts[:playlist_index],
      playlist_title: opts[:playlist_title]
    }

    batch = opts[:batch_id]

    with {:ok, job} <- Oban.insert(new(args, tags: List.wrap(batch))) do
      Beatgrid.Jobs.follow_download(job, batch)
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url} = args}) do
    # Old jobs may contain an expiring media URL. Their video ID is durable.
    url =
      case Link.video(args["video_id"]) do
        {:video, _} = video -> Link.url(video)
        :invalid -> url
      end

    case YouTube.download_and_ingest(url, playlist(args)) do
      {:ok, _count} ->
        mark_imported(args["recommendation_id"])
        YouTube.broadcast_tick()
        :ok

      {:error, %Beatgrid.Error{code: :rate_limited} = error} ->
        {:error, error}

      {:error, %Beatgrid.Error{code: code} = error}
      when code in [:video_unavailable, :verification_required, :invalid_link] ->
        {:cancel, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_imported(nil), do: :ok

  defp mark_imported(id) do
    if rec = Beatgrid.Repertoire.get_recommendation(id),
      do: Beatgrid.Repertoire.set_recommendation_status(rec, :imported)
  end

  # Rebuilds the playlist provenance from the job args (nil for a single video).
  defp playlist(%{"playlist_url" => url} = args) when is_binary(url) do
    %{url: url, index: args["playlist_index"], title: args["playlist_title"]}
  end

  defp playlist(_args), do: nil

  # YouTube rate-limits hard; after a 429 wait at least ~30s and back off further
  # on repeats. Anything else uses Oban's default exponential backoff.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt} = job) do
    if last_error_rate_limited?(job), do: min(30 * attempt, 300), else: super(job)
  end

  # Oban persists errors as strings, so this is the one place that still greps:
  # YtDlpError keeps "429" in the :rate_limited message precisely so it survives
  # into the persisted error (old-format errors carried the raw excerpt, which
  # also contains it).
  defp last_error_rate_limited?(%Oban.Job{errors: errors}) do
    case List.last(errors || []) do
      %{"error" => message} when is_binary(message) ->
        message =~ "429" or message =~ "Too Many Requests"

      _ ->
        false
    end
  end
end
