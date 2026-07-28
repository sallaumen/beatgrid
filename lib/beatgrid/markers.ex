defmodule Beatgrid.Markers do
  @moduledoc """
  Automatic cue-marker detection. Runs the `Audio.MarkerDetector` port on a track's
  file and writes the detected intro/outro/section markers (`source: "auto"`) onto
  its `cue_points` — replacing any prior auto markers but PRESERVING manual ones —
  then broadcasts so the player and the track page refresh.
  """
  import Ecto.Query, only: [from: 2]

  alias Beatgrid.Audio.MarkerDetector
  alias Beatgrid.Library
  alias Beatgrid.Library.{Marker, Track, Tracks}
  alias Beatgrid.Playback
  alias Beatgrid.Repo
  alias Beatgrid.Workers.MarkerAnalyzeWorker

  @topic "markers"

  @doc "Subscribe to marker-mapping progress (`{:markers_tick}` — contract: `Beatgrid.Events`)."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, @topic)

  @doc "Broadcast a progress tick so the Painel refreshes its marker counts."
  @spec broadcast_tick() :: :ok
  def broadcast_tick, do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, @topic, {:markers_tick})

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
      broadcast_tick()
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

  @doc "Mapped-vs-total counts over present tracks (for the Painel's progress bar)."
  @spec progress() :: %{mapped: non_neg_integer(), total: non_neg_integer()}
  def progress do
    tracks = Tracks.list_by(status: :present)
    %{mapped: Enum.count(tracks, &mapped?/1), total: length(tracks)}
  end

  @doc "Marker-analysis jobs still in flight — the live feedback for a re-map."
  @spec queued_count() :: non_neg_integer()
  def queued_count do
    Repo.aggregate(
      from(j in Oban.Job,
        where: j.worker == "Beatgrid.Workers.MarkerAnalyzeWorker",
        where: j.state in ["available", "scheduled", "executing", "retryable"]
      ),
      :count
    )
  end

  @doc """
  Enqueues a `MarkerAnalyzeWorker` for every present track without auto markers
  (manual markers are preserved by the worker). Returns `{:ok, enqueued_count}`.
  """
  @spec enqueue_unmapped() :: {:ok, non_neg_integer()}
  def enqueue_unmapped, do: enqueue_ids(unmapped_ids())

  @doc """
  Re-enqueues marker analysis for EVERY present track — the rollout path after
  a detector upgrade. Auto markers are replaced; manual ones survive.
  """
  @spec enqueue_all() :: {:ok, non_neg_integer()}
  def enqueue_all do
    [status: :present]
    |> Tracks.list_by()
    |> Enum.map(& &1.id)
    |> enqueue_ids()
  end

  defp enqueue_ids(ids) do
    count =
      Enum.reduce(ids, 0, fn id, acc ->
        case MarkerAnalyzeWorker.enqueue(id) do
          {:ok, _job} -> acc + 1
          _error -> acc
        end
      end)

    {:ok, count}
  end

  defp mapped?(%Track{cue_points: cues}), do: Enum.any?(cues || [], &Marker.auto?/1)
end
