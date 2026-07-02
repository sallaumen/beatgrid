defmodule Beatgrid.Analysis do
  @moduledoc """
  Local audio analysis — runs the `Audio.Analyzer` port on a track's file and
  stores the detected BPM + Camelot alongside the Soundcharts metadata, as a free,
  offline second opinion (useful to spot suspect Soundcharts values). Use
  `analyze_track/1`; `mix beatgrid.analyze` backfills the whole library.
  """
  alias Beatgrid.Library
  alias Beatgrid.Library.{Track, Tracks}
  alias Beatgrid.Soundcharts.Camelot
  alias Beatgrid.Workers.AnalyzeWorker

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.Audio.Analyzer, :adapter],
             Beatgrid.Audio.LibrosaCli
           )

  @topic "analysis"

  @doc "Subscribe to live analysis progress ticks (broadcast per analyzed track)."
  @spec subscribe() :: :ok
  def subscribe, do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, @topic)

  @doc "Broadcast a progress tick so subscribers refresh their counts."
  @spec broadcast_tick() :: :ok
  def broadcast_tick, do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, @topic, {:analysis_tick})

  @doc "Analyzed-vs-total counts over present tracks (for the progress bar)."
  @spec progress() :: %{analyzed: non_neg_integer(), total: non_neg_integer()}
  def progress do
    %{
      analyzed: Tracks.count(status: :present, analyzed: true),
      total: Tracks.count(status: :present)
    }
  end

  @doc "Enqueues a background analysis job for every not-yet-analyzed present track."
  @spec enqueue_pending() :: {:ok, non_neg_integer()}
  def enqueue_pending do
    count =
      [status: :present, analyzed: false]
      |> Tracks.list_by()
      |> Enum.reduce(0, fn track, acc ->
        case AnalyzeWorker.enqueue(track.id) do
          {:ok, _job} -> acc + 1
          _error -> acc
        end
      end)

    {:ok, count}
  end

  @spec analyze_track(Track.t()) :: {:ok, Track.t()} | {:error, term()}
  def analyze_track(%Track{} = track) do
    with {:ok, %{bpm: bpm, key: key, mode: mode}} <- @adapter.analyze(abs_path(track)) do
      Tracks.update(track, %{
        bpm_detected: bpm,
        camelot_detected: Camelot.from_key(key, mode),
        analyzed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })
    end
  end

  defp abs_path(track), do: Path.join(Library.library_root(), track.rel_path)
end
