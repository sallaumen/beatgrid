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

  @doc """
  Fuzzy signatures (`"norm_artist|norm_title"`) of every present track that has
  both fields, as a `MapSet`. Used to flag import near-duplicates (same artist +
  title) before importing. Blank-field tracks are excluded.
  """
  @spec present_signatures() :: MapSet.t(String.t())
  def present_signatures do
    list_by(status: :present)
    |> Enum.reduce(MapSet.new(), fn t, acc ->
      case signature(t.norm_artist, t.norm_title) do
        nil -> acc
        sig -> MapSet.put(acc, sig)
      end
    end)
  end

  @doc "Fuzzy signature `\"norm_artist|norm_title\"`, or nil if either part is blank."
  @spec signature(String.t() | nil, String.t() | nil) :: String.t() | nil
  def signature(norm_artist, norm_title) do
    if present?(norm_artist) and present?(norm_title), do: "#{norm_artist}|#{norm_title}"
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @spec update(Track.t(), map()) :: {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def update(track, attrs), do: track |> Track.changeset(attrs) |> Repo.update()

  @doc "Remove permanentemente o REGISTRO da faixa (o arquivo é tratado por Library.hard_delete/1)."
  @spec delete(Track.t()) :: {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Track{} = track), do: Repo.delete(track)

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
