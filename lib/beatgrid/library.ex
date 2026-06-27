defmodule Beatgrid.Library do
  @moduledoc """
  The Library context — the librarian over the on-disk music collection.

  The filesystem under `library_root/0` is the source of truth; this context
  reflects and edits it. It owns library initialization and the file-moving
  primitives (relocate, quarantine) that back the organization workflow.
  """
  alias Beatgrid.Library.{FileInfo, GenreFolders, MetadataAI, Track, Tracks}
  alias Beatgrid.YouTube.TitleParser

  @structural_dirs ["_Inbox", "_Quarantine"]

  @doc "The on-disk library root (the source of truth)."
  @spec library_root() :: String.t()
  def library_root, do: Application.fetch_env!(:beatgrid, :library_root)

  @doc """
  Creates the library root and its folders (one per genre folder, plus the
  structural `_Inbox` and `_Quarantine`). Idempotent. Returns the created paths.
  """
  # Note: `root` comes from app config and `dir_name`s from DB-seeded reference data —
  # never external input — so the directory creation below is not a traversal risk.
  @spec init_library(String.t()) :: {:ok, [String.t()]}
  def init_library(root \\ library_root()) do
    dir_names = Enum.map(GenreFolders.list(), & &1.dir_name) ++ @structural_dirs
    paths = Enum.map(dir_names, &Path.join(root, &1))

    File.mkdir_p!(root)
    Enum.each(paths, &File.mkdir_p!/1)

    {:ok, paths}
  end

  @doc """
  Copies audio files from `source_dir` into `_Inbox`, recording provenance
  (`source_playlist`). Skips files whose content already exists in the library
  (exact-hash dedup). Originals are left untouched.
  """
  @spec import_from(String.t()) ::
          {:ok, %{imported: non_neg_integer(), skipped: non_neg_integer()}}
  def import_from(source_dir) do
    source_dir = Path.expand(source_dir)
    File.mkdir_p!(abs_path("_Inbox"))

    {summary, _seen} =
      source_dir
      |> FileInfo.audio_files()
      |> Enum.reduce({%{imported: 0, skipped: 0}, library_hashes()}, fn file, {acc, seen} ->
        import_one(file, source_dir, acc, seen)
      end)

    {:ok, summary}
  end

  @doc """
  Read-only enrich-before-import dry run: previews what an import of `source`
  (a folder or a single audio file) would create, WITHOUT touching disk or DB.

  Returns one row per candidate audio file with the proposed `artist`/`title`
  (heuristic from tags or the filename, optionally refined by the AI when
  `opts[:ai]` — the default), plus `duplicate: true` for files whose content
  hash already exists in the library. The user reviews/edits these before the
  real, copying import runs (`import_files/3`).

  Writes nothing — no `File.cp`/`File.write`, no `Repo`/`Tracks` mutation.
  """
  @spec preview_import(String.t(), keyword()) :: {:ok, [map()]} | {:error, :not_found}
  def preview_import(source, opts \\ []) do
    source = Path.expand(source)

    cond do
      File.dir?(source) -> {:ok, source |> FileInfo.audio_files() |> build_rows(opts)}
      File.regular?(source) and FileInfo.audio?(source) -> {:ok, build_rows([source], opts)}
      true -> {:error, :not_found}
    end
  end

  # Build a preview row per file (read-only), then optionally refine the
  # artist-less ones with one batched AI call (mirrors YouTube.refine_titles).
  defp build_rows(paths, opts) do
    seen = library_hashes()

    paths
    |> Enum.map(&base_row(&1, seen))
    |> refine_rows(Keyword.get(opts, :ai, true))
  end

  defp base_row(path, seen) do
    info = FileInfo.read(path)
    sha = info[:content_sha256]
    %{artist: artist, title: title} = proposed_names(info)

    %{
      source_path: path,
      filename: info.filename,
      artist: artist,
      title: title,
      duration_ms: info[:duration_ms],
      format: info[:format],
      sha256: sha,
      duplicate: is_binary(sha) and MapSet.member?(seen, sha)
    }
  end

  # Tags win; otherwise parse the filename (sans extension) with the heuristic.
  defp proposed_names(info) do
    case {info[:tag_artist], info[:tag_title]} do
      {artist, title} when is_binary(artist) and is_binary(title) ->
        %{artist: artist, title: title}

      {artist, _title} ->
        stem = Path.rootname(info.filename)
        parsed = TitleParser.parse(stem)
        %{artist: artist || parsed.artist, title: info[:tag_title] || parsed.title}
    end
  end

  # Only refine rows still missing a clean artist; one batched parse_titles call.
  defp refine_rows(rows, false), do: rows

  defp refine_rows(rows, true) do
    ambiguous = Enum.filter(rows, &is_nil(&1.artist))

    with [_ | _] <- ambiguous,
         {:ok, parsed} <- MetadataAI.parse_titles(Enum.map(ambiguous, &raw_title/1)) do
      overlay = ambiguous |> Enum.zip(parsed) |> Map.new(fn {row, p} -> {row.source_path, p} end)
      Enum.map(rows, &apply_overlay(&1, overlay[&1.source_path]))
    else
      _ -> rows
    end
  end

  defp apply_overlay(row, %{artist: a, title: t}), do: %{row | artist: a, title: t}
  defp apply_overlay(row, _none), do: row

  defp raw_title(row), do: row.title || Path.rootname(row.filename)

  @doc """
  Moves a track's file to `dest_rel` (relative to the library root) and updates
  the row's `rel_path` and `genre_folder`. Never overwrites an existing file —
  a colliding destination gets a unique " (N)" suffix.
  """
  @spec relocate(Track.t(), String.t(), String.t() | nil) :: {:ok, Track.t()} | {:error, term()}
  def relocate(track, dest_rel, genre_folder) do
    do_move(track, dest_rel, %{genre_folder: genre_folder})
  end

  @doc """
  Renames a track's file in place (same directory) to `new_filename`, updating
  the row's `filename` and `rel_path`. Never overwrites — a colliding name gets
  a unique " (N)" suffix.
  """
  @spec rename(Track.t(), String.t()) :: {:ok, Track.t()} | {:error, term()}
  def rename(track, new_filename) do
    dest_rel = Path.join(Path.dirname(track.rel_path), new_filename)
    do_move(track, dest_rel, %{})
  end

  @doc "Moves a track into `_Quarantine` and flags its status. Never deletes."
  @spec quarantine(Track.t()) :: {:ok, Track.t()} | {:error, term()}
  def quarantine(track) do
    do_move(track, Path.join("_Quarantine", track.filename), %{
      status: :quarantined,
      genre_folder: nil
    })
  end

  @doc "Genre-folder key whose `dir_name` is the top segment of `rel`, or nil."
  @spec genre_folder_for_rel(String.t()) :: String.t() | nil
  def genre_folder_for_rel(rel) do
    top = rel |> Path.split() |> List.first()
    Enum.find_value(GenreFolders.list(), fn f -> if f.dir_name == top, do: f.key end)
  end

  defp do_move(track, dest_rel, extra_attrs) do
    src = abs_path(track.rel_path)

    with :ok <- check_source(src),
         unique_rel = ensure_unique(dest_rel),
         dest = abs_path(unique_rel),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- File.rename(src, dest) do
      Tracks.update(
        track,
        Map.merge(extra_attrs, %{rel_path: unique_rel, filename: Path.basename(unique_rel)})
      )
    end
  end

  defp check_source(src), do: if(File.exists?(src), do: :ok, else: {:error, :source_missing})

  defp abs_path(rel), do: Path.join(library_root(), rel)

  defp ensure_unique(rel) do
    if File.exists?(abs_path(rel)), do: ensure_unique(bump(rel)), else: rel
  end

  defp bump(rel) do
    dir = Path.dirname(rel)
    ext = Path.extname(rel)
    base = Path.basename(rel, ext)

    {stem, next} =
      case Regex.run(~r/^(.*) \((\d+)\)$/, base) do
        [_, stem, num] -> {stem, String.to_integer(num) + 1}
        _ -> {base, 2}
      end

    Path.join(dir, "#{stem} (#{next})#{ext}")
  end

  defp import_one(file, source_dir, acc, seen) do
    info = FileInfo.read(file)
    sha = info.content_sha256

    if is_binary(sha) and MapSet.member?(seen, sha) do
      {Map.update!(acc, :skipped, &(&1 + 1)), seen}
    else
      dest_rel = ensure_unique(Path.join("_Inbox", info.filename))
      File.cp!(file, abs_path(dest_rel))

      attrs =
        Map.merge(info, %{
          rel_path: dest_rel,
          source_playlist: source_playlist(file, source_dir),
          status: :present,
          last_scanned_at: DateTime.truncate(DateTime.utc_now(), :second)
        })

      {:ok, _track} = Tracks.upsert_by_path(attrs)
      {Map.update!(acc, :imported, &(&1 + 1)), MapSet.put(seen, sha)}
    end
  end

  defp library_hashes do
    Tracks.list_by(status: :present)
    |> Enum.map(& &1.content_sha256)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp source_playlist(file, source_dir) do
    case file |> Path.relative_to(source_dir) |> Path.split() do
      [_filename] -> Path.basename(source_dir)
      [top | _rest] -> top
    end
  end
end
