defmodule Beatgrid.Loudness do
  @moduledoc """
  Loudness analysis — measures a track's integrated loudness (LUFS) + true peak via
  the `Audio.Loudness` port and stores them, plus the domain helpers around them: the
  configurable normalization target and the headroom-safe suggested gain. Offline and
  quota-free (`mix`/the Painel button backfill the library). Mirrors `Beatgrid.Analysis`.
  """
  alias Beatgrid.Library
  alias Beatgrid.Library.{Track, Tracks}
  alias Beatgrid.Workers.LoudnessWorker

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.Audio.Loudness, :adapter],
             Beatgrid.Audio.FfmpegLoudness
           )

  # Normalization reference (LUFS) and the true-peak ceiling (dBTP) a suggested boost
  # must not exceed, so applying the gain can't clip. Backend-driven (config), shown
  # in the UI — never hardcoded in the front.
  @target_lufs Application.compile_env(:beatgrid, [__MODULE__, :target_lufs], -14.0)
  @ceiling_dbtp -1.0

  @topic "loudness"

  @doc "The normalization target in LUFS (config-driven; default -14)."
  @spec target_lufs() :: float()
  def target_lufs, do: @target_lufs

  @doc """
  Headroom-safe suggested gain (dB) to reach the target. A cut (negative) is always
  safe; a boost is capped so the resulting true peak stays under the ceiling. `nil`
  when unmeasured; if true peak is unknown, the boost is uncapped.
  """
  @spec gain_db(float() | nil, float() | nil) :: float() | nil
  def gain_db(nil, _true_peak), do: nil
  def gain_db(lufs, nil), do: Float.round(@target_lufs - lufs, 1)

  def gain_db(lufs, true_peak),
    do: Float.round(min(@target_lufs - lufs, @ceiling_dbtp - true_peak), 1)

  @doc "Subscribe to live loudness-analysis progress ticks."
  @spec subscribe() :: :ok
  def subscribe, do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, @topic)

  @doc "Broadcast a progress tick so subscribers refresh their counts."
  @spec broadcast_tick() :: :ok
  def broadcast_tick, do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, @topic, {:loudness_tick})

  @doc """
  Attempted-vs-total counts over present tracks (for the progress bar). Counts
  *attempted* (not just successfully measured) so a deterministically unmeasurable
  file — silence/corrupt — doesn't keep the bar below 100% forever.
  """
  @spec progress() :: %{measured: non_neg_integer(), total: non_neg_integer()}
  def progress do
    %{
      measured: Tracks.count(status: :present, loudness_attempted: true),
      total: Tracks.count(status: :present)
    }
  end

  @doc "Enqueues a background loudness job for every not-yet-attempted present track."
  @spec enqueue_pending() :: {:ok, non_neg_integer()}
  def enqueue_pending do
    count =
      [status: :present, loudness_attempted: false]
      |> Tracks.list_by()
      |> Enum.reduce(0, fn track, acc ->
        case Oban.insert(LoudnessWorker.new(%{track_id: track.id})) do
          {:ok, _job} -> acc + 1
          _error -> acc
        end
      end)

    {:ok, count}
  end

  @doc """
  Measures a track and stores its LUFS + true peak. Always stamps `loudness_attempted_at`
  so the track leaves the pending set: a successful measure stores the values; a
  deterministically unmeasurable file (silence/corrupt → `:no_loudness_data`) is marked
  attempted without a value (no point retrying); a transient error (missing file / ffmpeg
  unavailable) returns the error so the worker retries.
  """
  @spec measure_track(Track.t()) :: {:ok, Track.t()} | {:error, term()}
  def measure_track(%Track{} = track) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    case @adapter.measure(abs_path(track)) do
      {:ok, %{lufs: lufs, true_peak: true_peak}} ->
        Tracks.update(track, %{
          loudness_lufs: lufs,
          true_peak_dbtp: true_peak,
          loudness_attempted_at: now
        })

      {:error, :no_loudness_data} ->
        Tracks.update(track, %{loudness_attempted_at: now})

      other ->
        other
    end
  end

  defp abs_path(track), do: Path.join(Library.library_root(), track.rel_path)
end
