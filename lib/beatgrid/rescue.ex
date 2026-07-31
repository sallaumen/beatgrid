defmodule Beatgrid.Rescue do
  @moduledoc """
  The library's emergency room. Finds tracks that can no longer PLAY — files
  deleted outside the app (the scan never ran, so they still read `present`)
  and files that stopped decoding (the old in-place gain writer could
  half-write on a brutal kill) — and restores them from the pre-gain backups
  under `_Backups/Gain`, or brings a dedup-quarantined copy back.

  A restore re-measures loudness and resets the applied gain, so the Painel's
  apply-gain flow picks the track up naturally afterwards.
  """

  alias Beatgrid.Library
  alias Beatgrid.Library.{Track, Tracks}
  alias Beatgrid.Loudness
  alias Beatgrid.Operations
  alias Beatgrid.Operations.Operation
  alias Beatgrid.Rescue.RescueQuery
  alias Beatgrid.Workers.IntegrityCheckWorker

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.Audio.IntegrityChecker, :adapter],
             Beatgrid.Audio.IntegrityCheckerCli
           )

  @topic "rescue"

  @doc "Subscribe to census updates (`{:integrity_checked, track_id}`)."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, @topic)

  @doc "Checks one track's playability and persists the verdict."
  @spec check(Track.t()) :: {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def check(%Track{} = track) do
    verdict = @adapter.check(Path.join(Library.library_root(), track.rel_path))

    with {:ok, updated} <- Tracks.update(track, integrity_attrs(verdict)) do
      broadcast({:integrity_checked, updated.id})
      {:ok, updated}
    end
  end

  @doc "Enqueues an integrity check for every present track; `{:ok, count}`."
  @spec enqueue_check_all() :: {:ok, non_neg_integer()}
  def enqueue_check_all do
    count =
      [status: :present]
      |> Tracks.list_by()
      |> Enum.reduce(0, fn track, acc ->
        case IntegrityCheckWorker.enqueue(track.id) do
          {:ok, _job} -> acc + 1
          _error -> acc
        end
      end)

    {:ok, count}
  end

  @doc "Present-track census by integrity status."
  @spec progress() :: %{atom() => non_neg_integer()}
  defdelegate progress, to: RescueQuery, as: :integrity_counts

  @doc "Damaged present tracks with their restorable backup (nil = none on disk)."
  @spec damaged() :: [%{track: Track.t(), backup_rel: String.t() | nil}]
  def damaged do
    for track <- RescueQuery.damaged() do
      %{track: track, backup_rel: available_backup(track)}
    end
  end

  @doc "Quarantined tracks with the original path a restore would return them to."
  @spec quarantined() :: [%{track: Track.t(), restore_rel: String.t() | nil}]
  def quarantined do
    root = Library.library_root()

    for track <- Tracks.list_by(status: :quarantined) do
      %{
        track: track,
        restore_rel: quarantine_origin(track),
        # A ghost: the DB row survived but the file left _Quarantine (deleted
        # by hand or by dump retention) — restoring is impossible; the screen
        # must say so instead of offering a button that fails.
        file?: File.exists?(Path.join(root, track.rel_path))
      }
    end
  end

  @doc """
  Restores a damaged track's audio from its latest gain backup, then re-checks
  integrity so the census reflects the rescue immediately.
  """
  @spec restore_from_backup(Track.t()) :: {:ok, Track.t()} | {:error, term()}
  def restore_from_backup(%Track{} = track) do
    case available_backup(track) do
      nil ->
        {:error, :no_backup}

      backup_rel ->
        with {:ok, restored} <- Loudness.restore_gain_backup(track, backup_rel) do
          check(restored)
        end
    end
  end

  @doc "Restores every damaged track that has a backup; counts what happened."
  @spec restore_all_from_backup() ::
          {:ok, %{restored: non_neg_integer(), failed: non_neg_integer()}}
  def restore_all_from_backup do
    results =
      for %{track: track, backup_rel: rel} <- damaged(), is_binary(rel) do
        restore_from_backup(track)
      end

    {:ok,
     %{
       restored: Enum.count(results, &match?({:ok, _}, &1)),
       failed: Enum.count(results, &(not match?({:ok, _}, &1)))
     }}
  end

  @doc "Brings a quarantined copy back to its original path and `:present`."
  @spec restore_from_quarantine(Track.t()) :: {:ok, Track.t()} | {:error, term()}
  def restore_from_quarantine(%Track{} = track) do
    case latest_quarantine_operation(track) do
      nil ->
        {:error, :no_quarantine_origin}

      operation ->
        case Operations.undo_operation(operation) do
          :undone -> {:ok, Tracks.get(track.id)}
          :failed -> {:error, :restore_failed}
        end
    end
  end

  defp integrity_attrs(verdict) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    base = %{integrity_checked_at: now, integrity_error: nil}

    case verdict do
      :ok ->
        Map.put(base, :integrity_status, :ok)

      {:error, :enoent} ->
        Map.put(base, :integrity_status, :missing_file)

      {:error, {:corrupt, message}} ->
        %{base | integrity_error: message}
        |> Map.put(:integrity_status, :corrupt)
    end
  end

  defp available_backup(track) do
    with rel when is_binary(rel) <- Operations.latest_gain_backup(track.id),
         true <- File.regular?(Path.join(Library.library_root(), rel)) do
      rel
    else
      _missing -> nil
    end
  end

  defp latest_quarantine_operation(track) do
    case Operations.list_by(track_id: track.id, kind: :quarantine, status: :applied, limit: 1) do
      [%Operation{} = operation | _] -> operation
      _none -> nil
    end
  end

  defp quarantine_origin(track) do
    case latest_quarantine_operation(track) do
      %Operation{from: from} -> from
      nil -> nil
    end
  end

  defp broadcast(message),
    do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, @topic, message)
end
