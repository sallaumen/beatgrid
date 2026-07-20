defmodule Beatgrid.Workers.MixDownloadWorker do
  @moduledoc """
  Downloads one online set (SoundCloud) into `<library_root>/_Mixes` via the
  `Mixes.Source` adapter, fills the mix's metadata, and marks it ready. Retry policy
  mirrors the YouTube DownloadWorker: a 429 backs off and retries; a permanent
  "unavailable" cancels and marks the mix failed. (Phase 2 will enqueue the analysis
  step here instead of going straight to :ready.)
  """
  use Oban.Worker,
    queue: :mixes,
    max_attempts: 10,
    unique: [
      period: 3600,
      keys: [:mix_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Beatgrid.Library
  alias Beatgrid.Mixes
  alias Beatgrid.Workers.MixAnalyzeWorker

  @spec enqueue(Beatgrid.Mixes.Mix.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%Beatgrid.Mixes.Mix{id: id}, opts \\ []) do
    args = if opts[:restore_only], do: %{mix_id: id, restore_only: true}, else: %{mix_id: id}
    args |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mix_id" => mix_id} = args}) do
    case Mixes.get_mix(mix_id) do
      nil ->
        {:cancel, :mix_not_found}

      mix ->
        dest = Path.join(Library.library_root(), "_Mixes")

        case Mixes.fetch_source(mix.source_url, dest) do
          {:ok, meta} -> on_fetched(mix, meta, args["restore_only"] == true)
          {:error, reason} -> handle_error(mix, reason)
        end
    end
  end

  # restore-only (re-download of a purged file): bring the audio back and ready the mix,
  # but do NOT re-run analysis — the segments/DJ parts are already there.
  defp on_fetched(mix, meta, true) do
    {:ok, _} =
      Mixes.update_mix(mix, %{
        audio_path: meta[:audio_path],
        audio_deleted_at: nil,
        status: :ready
      })

    Mixes.broadcast(%{mix_id: mix.id, status: :ready})
    :ok
  end

  defp on_fetched(mix, meta, _restore_only) do
    {:ok, mix} = Mixes.update_mix(mix, Map.put(meta, :status, :analyzing))
    {:ok, _} = MixAnalyzeWorker.enqueue(mix)
    Mixes.broadcast(%{mix_id: mix.id, status: :analyzing})
    :ok
  end

  # Branches on the code the yt-dlp adapter classifies (Beatgrid.YtDlpError):
  # rate limits retry with the long backoff, permanent refusals mark the mix
  # failed and cancel.
  defp handle_error(mix, reason) do
    case reason do
      %Beatgrid.Error{code: :rate_limited} ->
        {:error, reason}

      %Beatgrid.Error{code: :video_unavailable} ->
        {:ok, _} = Mixes.update_mix(mix, %{status: :failed, error: inspect(reason)})
        Mixes.broadcast(%{mix_id: mix.id, status: :failed})
        {:cancel, reason}

      _ ->
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt} = job) do
    if last_error_rate_limited?(job), do: min(30 * attempt, 300), else: super(job)
  end

  defp last_error_rate_limited?(%Oban.Job{errors: errors}) do
    case List.last(errors || []) do
      %{"error" => message} when is_binary(message) ->
        message =~ "429" or message =~ "Too Many Requests"

      _ ->
        false
    end
  end
end
