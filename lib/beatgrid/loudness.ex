defmodule Beatgrid.Loudness do
  @moduledoc """
  Loudness analysis — measures a track's integrated loudness (LUFS) + true peak via
  the `Audio.Loudness` port and stores them, plus the domain helpers around them: the
  configurable normalization target and the headroom-safe suggested gain. Offline and
  quota-free (`mix`/the Painel button backfill the library). Mirrors `Beatgrid.Analysis`.
  """
  alias Beatgrid.Library
  alias Beatgrid.Library.{Track, Tracks}
  alias Beatgrid.Operations
  alias Beatgrid.Workers.{GainApplyWorker, LoudnessWorker}

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.Audio.Loudness, :adapter],
             Beatgrid.Audio.FfmpegLoudness
           )

  @gain_adapter Application.compile_env(
                  :beatgrid,
                  [Beatgrid.Audio.GainApplier, :adapter],
                  Beatgrid.Audio.GainApplierCli
                )

  # Normalization reference (LUFS) and the true-peak ceiling (dBTP) a suggested boost
  # must not exceed, so applying the gain can't clip. Backend-driven (config), shown
  # in the UI — never hardcoded in the front.
  @target_lufs Application.compile_env(:beatgrid, [__MODULE__, :target_lufs], -14.0)
  @gain_tolerance_db Application.compile_env(:beatgrid, [__MODULE__, :gain_tolerance_db], 1.0)
  @ceiling_dbtp -1.0

  @topic "loudness"

  @doc "The normalization target in LUFS (config-driven; default -14)."
  @spec target_lufs() :: float()
  def target_lufs, do: @target_lufs

  @doc "The minimum absolute gain worth applying to a file."
  @spec gain_tolerance_db() :: float()
  def gain_tolerance_db, do: @gain_tolerance_db

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

  @doc "Returns true when a measured track is outside the gain tolerance band."
  @spec needs_gain?(Track.t()) :: boolean()
  def needs_gain?(%Track{} = track) do
    case gain_db(track.loudness_lufs, track.true_peak_dbtp) do
      nil -> false
      gain -> abs(gain) >= @gain_tolerance_db
    end
  end

  @doc "Measured present tracks that have not yet had gain applied and are outside tolerance."
  @spec gain_pending() :: [Track.t()]
  def gain_pending do
    [status: :present, loudness: true]
    |> Tracks.list_by()
    |> Enum.filter(&(is_nil(&1.gain_applied_at) and needs_gain?(&1)))
  end

  @doc "Count of measured present tracks still eligible for gain application."
  @spec gain_pending_count() :: non_neg_integer()
  def gain_pending_count, do: gain_pending() |> length()

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

  @doc "Enqueues a background gain-apply job for every eligible measured track."
  @spec enqueue_apply_pending() :: {:ok, non_neg_integer(), Ecto.UUID.t()}
  def enqueue_apply_pending do
    batch_id = Uniq.UUID.uuid7()

    count =
      gain_pending()
      |> Enum.reduce(0, fn track, acc ->
        case Oban.insert(GainApplyWorker.new(%{track_id: track.id, batch_id: batch_id})) do
          {:ok, _job} -> acc + 1
          _error -> acc
        end
      end)

    {:ok, count, batch_id}
  end

  @doc "Most recent applied gain batch, if any backup can be restored."
  @spec latest_gain_batch() :: Ecto.UUID.t() | nil
  def latest_gain_batch do
    case Operations.list_by(kind: :gain, status: :applied, limit: 1) do
      [%{batch_id: batch_id} | _] -> batch_id
      [] -> nil
    end
  end

  @doc """
  Measures a track and stores its LUFS + true peak. Always stamps `loudness_attempted_at`
  so the track leaves the pending set: a successful measure stores the values; a
  deterministically unmeasurable file (silence/corrupt → `:no_loudness_data`) is marked
  attempted without a value (no point retrying); a transient error (missing file / ffmpeg
  unavailable) returns the error so the worker retries.
  """
  @spec measure_track(Track.t(), keyword()) :: {:ok, Track.t()} | {:error, term()}
  def measure_track(%Track{} = track, opts \\ []) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    origin = Keyword.get(opts, :origin, :library_file)

    case @adapter.measure(abs_path(track)) do
      {:ok, %{lufs: lufs, true_peak: true_peak}} ->
        Tracks.update(track, %{
          loudness_lufs: lufs,
          true_peak_dbtp: true_peak,
          loudness_attempted_at: now,
          loudness_measurement_origin: origin
        })

      {:error, :no_loudness_data} ->
        Tracks.update(track, %{
          loudness_attempted_at: now,
          loudness_measurement_origin: origin
        })

      other ->
        other
    end
  end

  @doc """
  Applies the current headroom-safe gain to a measured track, remeasures the file,
  marks the track, and records the reversible disk mutation.
  """
  @spec apply_gain(Track.t(), keyword()) :: {:ok, Track.t()} | {:error, term()}
  def apply_gain(%Track{} = track, opts \\ []) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    case gain_db(track.loudness_lufs, track.true_peak_dbtp) do
      nil ->
        {:error, :loudness_not_measured}

      gain when abs(gain) < @gain_tolerance_db ->
        Tracks.update(track, %{gain_applied_db: 0.0, gain_applied_at: now})

      gain ->
        batch_id = Keyword.get_lazy(opts, :batch_id, &Uniq.UUID.uuid7/0)

        with {:ok, backup_rel_path} <- backup_original(track, batch_id),
             :ok <- @gain_adapter.apply(abs_path(track), gain),
             {:ok, measured} <- measure_track(track, origin: :post_gain),
             {:ok, updated} <-
               Tracks.update(
                 measured,
                 Map.merge(original_snapshot_attrs(track, now), %{
                   gain_applied_db: gain,
                   gain_applied_at: now
                 })
               ),
             {:ok, _operation} <- record_gain_operation(updated, gain, backup_rel_path, batch_id) do
          {:ok, updated}
        end
    end
  end

  @doc false
  @spec restore_gain_backup(Track.t(), String.t()) :: {:ok, Track.t()} | {:error, term()}
  def restore_gain_backup(%Track{} = track, backup_rel_path) when is_binary(backup_rel_path) do
    with {:ok, backup_path} <- safe_library_path(backup_rel_path),
         :ok <- restore_backup_file(backup_path, abs_path(track)),
         {:ok, measured} <- measure_track(track, origin: :restore_backup) do
      Tracks.update(measured, %{gain_applied_db: nil, gain_applied_at: nil})
    end
  end

  defp original_snapshot_attrs(%Track{original_loudness_lufs: lufs}, _now) when is_number(lufs),
    do: %{}

  defp original_snapshot_attrs(track, now) do
    %{
      original_loudness_lufs: track.loudness_lufs,
      original_true_peak_dbtp: track.true_peak_dbtp,
      original_loudness_measured_at: track.loudness_attempted_at || now
    }
  end

  defp backup_original(track, batch_id) do
    backup_rel_path = Path.join(["_Backups", "Gain", track.id, batch_id, track.rel_path])

    with {:ok, backup_path} <- safe_library_path(backup_rel_path),
         true <- File.regular?(abs_path(track)) || {:error, :enoent},
         :ok <- File.mkdir_p(Path.dirname(backup_path)),
         :ok <- File.cp(abs_path(track), backup_path) do
      {:ok, backup_rel_path}
    end
  end

  defp restore_backup_file(backup_path, target_path) do
    tmp = Path.join(Path.dirname(target_path), ".restore-" <> Path.basename(target_path))

    with true <- File.regular?(backup_path) || {:error, :backup_not_found},
         :ok <- File.cp(backup_path, tmp),
         :ok <- non_empty_file(tmp),
         :ok <- File.rename(tmp, target_path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(tmp)
        error

      false ->
        File.rm(tmp)
        {:error, :backup_not_found}
    end
  end

  defp non_empty_file(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 -> :ok
      _ -> {:error, :empty_backup}
    end
  end

  defp safe_library_path(rel_path) do
    root = Path.expand(Library.library_root())
    path = Path.expand(Path.join(root, rel_path))

    if String.starts_with?(path, root <> "/"),
      do: {:ok, path},
      else: {:error, :invalid_backup_path}
  end

  defp record_gain_operation(track, gain, backup_rel_path, batch_id) do
    Operations.record(%{
      track_id: track.id,
      kind: :gain,
      from: to_string(gain),
      to: backup_rel_path,
      batch_id: batch_id
    })
  end

  defp abs_path(track), do: Path.join(Library.library_root(), track.rel_path)
end
