defmodule Beatgrid.Sets do
  @moduledoc """
  Harmonic set-builder. A `RecSet` is a named, ordered chain of tracks the user
  assembles for a gig. Tracks are appended one at a time from the harmonic
  candidates (`Mixing.suggest_next`, excluding what's already in the set), or the
  rest is filled in greedily (`auto_fill/2`). A finished set exports to an `.m3u`
  playlist under `<library_root>/_Sets` that Serato/VLC read directly.
  """
  import Ecto.Query

  alias Beatgrid.Library
  alias Beatgrid.Mixing
  alias Beatgrid.Repo
  alias Beatgrid.Sets.{RecSet, RecSetQuery, SetTrack}

  @unsafe ~r/[\/\\:*?"<>|]/u

  @spec list() :: [RecSet.t()]
  defdelegate list, to: RecSetQuery

  @spec get(Ecto.UUID.t()) :: RecSet.t() | nil
  defdelegate get(id), to: RecSetQuery

  @spec tracks(RecSet.t()) :: [Library.Track.t()]
  def tracks(%RecSet{id: id}), do: RecSetQuery.ordered_tracks(id)

  @spec create(String.t()) :: {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def create(name), do: %RecSet{} |> RecSet.changeset(%{name: name}) |> Repo.insert()

  @spec rename(RecSet.t(), String.t()) :: {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def rename(set, name), do: set |> RecSet.changeset(%{name: name}) |> Repo.update()

  @spec delete(RecSet.t()) :: {:ok, RecSet.t()} | {:error, Ecto.Changeset.t()}
  def delete(set), do: Repo.delete(set)

  @doc "Appends a track to the end of the set (a no-op if it's already a member)."
  @spec append(RecSet.t(), Library.Track.t()) :: {:ok, SetTrack.t()} | {:error, term()}
  def append(%RecSet{id: id}, track) do
    %SetTrack{}
    |> SetTrack.changeset(%{
      rec_set_id: id,
      track_id: track.id,
      position: RecSetQuery.count(id) + 1
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:rec_set_id, :track_id])
  end

  @doc "Removes a track from the set and re-numbers the remaining positions."
  @spec remove(RecSet.t(), Library.Track.t()) :: :ok
  def remove(%RecSet{id: id} = set, track) do
    SetTrack
    |> where([st], st.rec_set_id == ^id and st.track_id == ^track.id)
    |> Repo.delete_all()

    reindex(set)
    :ok
  end

  @doc "Moves a track one step up or down in the set (a no-op at the edges)."
  @spec move(RecSet.t(), Library.Track.t(), :up | :down) :: :ok
  def move(%RecSet{id: id}, track, direction) do
    rows = RecSetQuery.rows(id)
    idx = Enum.find_index(rows, &(&1.track_id == track.id))
    swap_idx = if idx, do: idx + step(direction)

    if idx && swap_idx in 0..(length(rows) - 1)//1 do
      swap_positions(Enum.at(rows, idx), Enum.at(rows, swap_idx))
    end

    :ok
  end

  defp step(:up), do: -1
  defp step(:down), do: 1

  defp swap_positions(a, b) do
    pa = a.position
    a |> SetTrack.changeset(%{position: b.position}) |> Repo.update()
    b |> SetTrack.changeset(%{position: pa}) |> Repo.update()
  end

  @doc "Ranked harmonic candidates to append next (from the last track, excluding members)."
  @spec next_candidates(RecSet.t(), keyword()) :: [Mixing.suggestion()]
  def next_candidates(%RecSet{id: id}, opts \\ []) do
    members = RecSetQuery.ordered_tracks(id)

    case List.last(members) do
      nil -> []
      last -> Mixing.suggest_next(last, Keyword.put(opts, :exclude, Enum.map(members, & &1.id)))
    end
  end

  @doc "Greedily appends up to `:count` (default 8) harmonically compatible tracks."
  @spec auto_fill(RecSet.t(), keyword()) :: {:ok, RecSet.t()}
  def auto_fill(set, opts \\ []) do
    fill(set, Keyword.get(opts, :count, 8))
    {:ok, set}
  end

  defp fill(_set, remaining) when remaining <= 0, do: :ok

  defp fill(set, remaining) do
    case next_candidates(set, limit: 1) do
      [%{track: next} | _] ->
        append(set, next)
        fill(set, remaining - 1)

      [] ->
        :ok
    end
  end

  @doc "Writes the set as an `.m3u` playlist under `<library_root>/_Sets`."
  @spec export_m3u(RecSet.t()) :: {:ok, Path.t()} | {:error, term()}
  def export_m3u(%RecSet{id: id, name: name}) do
    dir = Path.join(Library.library_root(), "_Sets")
    path = Path.join(dir, sanitize(name) <> ".m3u")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, m3u_body(RecSetQuery.ordered_tracks(id))) do
      {:ok, path}
    end
  end

  # --- internals ---

  defp reindex(%RecSet{id: id}) do
    id
    |> RecSetQuery.rows()
    |> Enum.with_index(1)
    |> Enum.each(fn {row, position} ->
      row |> SetTrack.changeset(%{position: position}) |> Repo.update()
    end)
  end

  defp m3u_body(tracks) do
    root = Library.library_root()
    lines = Enum.flat_map(tracks, &extinf(&1, root))
    Enum.join(["#EXTM3U" | lines], "\n") <> "\n"
  end

  defp extinf(track, root) do
    secs = if track.duration_ms, do: div(track.duration_ms, 1000), else: -1
    artist = track.tag_artist || "—"
    title = track.tag_title || track.filename
    ["#EXTINF:#{secs},#{artist} - #{title}", Path.join(root, track.rel_path)]
  end

  defp sanitize(name), do: (name || "set") |> String.replace(@unsafe, "-") |> String.trim()
end
