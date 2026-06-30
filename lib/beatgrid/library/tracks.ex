defmodule Beatgrid.Library.Tracks do
  @moduledoc """
  Context for tracks — the physical audio files in the library. Reads are
  delegated to `Beatgrid.Library.TrackQuery`; mutations live here.
  """
  import Ecto.Query

  alias Beatgrid.Library.{Marker, Normalize, Track, TrackQuery, Version}
  alias Beatgrid.Repo

  defdelegate get(id), to: TrackQuery
  defdelegate get_with_song(id), to: TrackQuery
  defdelegate get_by_path(rel_path), to: TrackQuery
  defdelegate all_tags(), to: TrackQuery

  @spec list_by(keyword()) :: [Track.t()]
  def list_by(opts \\ []), do: TrackQuery.list_by(opts)

  @doc """
  Other present tracks that are *different versions* of the same song — same
  artist + base title (markers stripped) but a different version rendering. Excludes
  the track itself and exact-content duplicates (those belong in dedup, not here).
  Returns each with its `soundcharts_song` preloaded, sorted by title.
  """
  @spec versions_of(Track.t()) :: [Track.t()]
  def versions_of(%Track{} = track) do
    if present?(track.norm_artist) do
      base = Version.base_key(track.tag_artist, version_title(track))
      self_norm = Normalize.normalize(version_title(track))

      Track
      |> where([t], t.status == :present and t.norm_artist == ^track.norm_artist)
      |> where([t], t.id != ^track.id)
      |> preload(:soundcharts_song)
      |> Repo.all()
      |> Enum.filter(fn t ->
        # A "different version" must render differently — compare the SAME
        # (filename-aware) title source base_key uses, not the tag-only norm_title.
        Version.base_key(t.tag_artist, version_title(t)) == base and
          Normalize.normalize(version_title(t)) != self_norm and
          not exact_dup?(t, track)
      end)
      |> Enum.sort_by(&version_title/1)
    else
      []
    end
  end

  defp version_title(track), do: track.tag_title || Path.rootname(track.filename || "")

  defp exact_dup?(%{content_sha256: a}, %{content_sha256: b})
       when is_binary(a) and is_binary(b),
       do: a == b

  defp exact_dup?(_a, _b), do: false

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

  @doc "Sets the label of the marker at `position_ms`; a blank label clears it. Unknown position is a no-op."
  @spec rename_marker(Track.t(), non_neg_integer(), String.t() | nil) ::
          {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def rename_marker(track, position_ms, label) do
    cues =
      Enum.map(track.cue_points || [], fn
        %{"ms" => ^position_ms} = marker -> Map.put(marker, "label", normalize_label(label))
        marker -> marker
      end)

    save_cues(track, cues)
  end

  @doc "Sets the `type` (coerced via `Marker.normalize_type`) of the marker at `position_ms`."
  @spec set_marker_type(Track.t(), non_neg_integer(), String.t()) ::
          {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def set_marker_type(track, position_ms, type) do
    cues =
      Enum.map(track.cue_points || [], fn
        %{"ms" => ^position_ms} = marker -> Map.put(marker, "type", Marker.normalize_type(type))
        marker -> marker
      end)

    save_cues(track, cues)
  end

  @doc "Replaces all auto-source markers with `auto_markers`, keeping manual ones, sorted by ms."
  @spec replace_auto_markers(Track.t(), [map()]) ::
          {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def replace_auto_markers(track, auto_markers) do
    manual = Enum.reject(track.cue_points || [], &Marker.auto?/1)
    save_cues(track, Enum.sort_by(manual ++ auto_markers, & &1["ms"]))
  end

  defp normalize_label(nil), do: nil

  defp normalize_label(label) when is_binary(label) do
    case String.trim(label) do
      "" -> nil
      trimmed -> trimmed
    end
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
