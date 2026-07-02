defmodule Beatgrid.Markers do
  @moduledoc """
  Automatic cue-marker detection. Runs the `Audio.MarkerDetector` port on a track's
  file and writes the detected intro/outro/section markers (`source: "auto"`) onto
  its `cue_points` — replacing any prior auto markers but PRESERVING manual ones —
  then broadcasts so the player and the track page refresh.
  """
  alias Beatgrid.Audio.MarkerDetector
  alias Beatgrid.Library
  alias Beatgrid.Library.{Marker, Track, Tracks}
  alias Beatgrid.Playback
  alias Beatgrid.Workers.MarkerAnalyzeWorker

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.Audio.MarkerDetector, :adapter],
             Beatgrid.Audio.MarkerDetectorCli
           )

  @doc "Detects markers for a track and persists them (auto markers), then broadcasts."
  @spec detect(Track.t()) :: {:ok, Track.t()} | {:error, term()}
  def detect(track) do
    with {:ok, detection} <- @adapter.detect(abs_path(track)),
         {:ok, updated} <- Tracks.replace_auto_markers(track, auto_markers(detection)) do
      Playback.broadcast_markers_changed(updated.id)
      {:ok, updated}
    end
  end

  @doc "Builds auto-marker maps from a detection (intro/outro + section cues)."
  @spec auto_markers(MarkerDetector.detection()) :: [map()]
  def auto_markers(detection) do
    sections = for ms <- detection[:sections] || [], do: marker(ms, "cue")

    [marker(detection[:intro_ms], "intro"), marker(detection[:outro_ms], "outro") | sections]
    |> Enum.reject(&is_nil/1)
  end

  defp marker(ms, type) when is_integer(ms) and ms >= 0,
    do: %{"ms" => ms, "label" => nil, "type" => type, "source" => "auto"}

  defp marker(_ms, _type), do: nil

  defp abs_path(track), do: Path.join(Library.library_root(), track.rel_path)

  # ---- bulk mapping (Painel) ----

  @doc "Ids of `present` tracks that have no automatic marker yet."
  @spec unmapped_ids() :: [binary()]
  def unmapped_ids do
    [status: :present]
    |> Tracks.list_by()
    |> Enum.reject(&mapped?/1)
    |> Enum.map(& &1.id)
  end

  @doc "How many `present` tracks still lack automatic markers."
  @spec unmapped_count() :: non_neg_integer()
  def unmapped_count, do: length(unmapped_ids())

  @doc """
  Enqueues a `MarkerAnalyzeWorker` for every present track without auto markers
  (manual markers are preserved by the worker). Returns `{:ok, enqueued_count}`.
  """
  @spec enqueue_unmapped() :: {:ok, non_neg_integer()}
  def enqueue_unmapped do
    count =
      unmapped_ids()
      |> Enum.reduce(0, fn id, acc ->
        case MarkerAnalyzeWorker.enqueue(id) do
          {:ok, _job} -> acc + 1
          _error -> acc
        end
      end)

    {:ok, count}
  end

  defp mapped?(%Track{cue_points: cues}), do: Enum.any?(cues || [], &Marker.auto?/1)
end
