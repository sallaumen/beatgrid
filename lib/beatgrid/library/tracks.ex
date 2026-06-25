defmodule Beatgrid.Library.Tracks do
  @moduledoc """
  Context for tracks — the physical audio files in the library. Reads are
  delegated to `Beatgrid.Library.TrackQuery`; mutations live here.
  """
  import Ecto.Query

  alias Beatgrid.Library.{Track, TrackQuery}
  alias Beatgrid.Repo

  defdelegate get_by_path(rel_path), to: TrackQuery

  @spec list_by(keyword()) :: [Track.t()]
  def list_by(opts \\ []), do: TrackQuery.list_by(opts)

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
