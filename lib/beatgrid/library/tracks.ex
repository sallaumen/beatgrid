defmodule Beatgrid.Library.Tracks do
  @moduledoc """
  Context for tracks — the physical audio files in the library. Reads are
  delegated to `Beatgrid.Library.TrackQuery`; mutations live here.
  """
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
end
