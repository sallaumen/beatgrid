defmodule Beatgrid.Library.Tracks do
  @moduledoc """
  Context for tracks — the physical audio files in the library. Reads are
  delegated to `Beatgrid.Library.TrackQuery`; mutations live here.
  """
  import Ecto.Query

  alias Beatgrid.Library.{Track, TrackQuery}
  alias Beatgrid.Repo

  defdelegate get(id), to: TrackQuery
  defdelegate get_with_song(id), to: TrackQuery
  defdelegate get_by_path(rel_path), to: TrackQuery

  @spec list_by(keyword()) :: [Track.t()]
  def list_by(opts \\ []), do: TrackQuery.list_by(opts)

  @spec update(Track.t(), map()) :: {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def update(track, attrs), do: track |> Track.changeset(attrs) |> Repo.update()

  @doc "Adds a cue-point marker at `position_ms` (optional label), kept sorted by position."
  @spec add_marker(Track.t(), non_neg_integer(), String.t() | nil) ::
          {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def add_marker(track, position_ms, label \\ nil) do
    marker = %{"ms" => position_ms, "label" => label}
    save_cues(track, Enum.sort_by((track.cue_points || []) ++ [marker], & &1["ms"]))
  end

  @doc "Removes the cue-point marker at `position_ms`."
  @spec remove_marker(Track.t(), non_neg_integer()) ::
          {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def remove_marker(track, position_ms) do
    save_cues(track, Enum.reject(track.cue_points || [], &(&1["ms"] == position_ms)))
  end

  defp save_cues(track, cues), do: track |> Track.changeset(%{cue_points: cues}) |> Repo.update()

  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []), do: TrackQuery.count(opts)

  @doc """
  Inserts a track, or updates the existing one at the same `rel_path`
  (idempotent re-scan). Derives normalized matching fields.
  """
  @spec upsert_by_path(map()) :: {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def upsert_by_path(attrs) do
    rel_path = attrs[:rel_path] || attrs["rel_path"]
    existing = rel_path && TrackQuery.get_by_path(rel_path)

    (existing || %Track{})
    |> Track.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Marks every `:present` track whose `rel_path` is not in `scanned_rel_paths`
  as `:missing` (the file disappeared since the last scan). Returns the count.
  """
  @spec mark_missing_except([String.t()]) :: non_neg_integer()
  def mark_missing_except(scanned_rel_paths) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {count, _} =
      Track
      |> where([t], t.status == :present and t.rel_path not in ^scanned_rel_paths)
      |> Repo.update_all(set: [status: :missing, updated_at: now])

    count
  end
end
