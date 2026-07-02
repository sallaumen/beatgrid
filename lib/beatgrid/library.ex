defmodule Beatgrid.Library do
  @moduledoc """
  The Library context — the librarian over the on-disk music collection.

  The filesystem under `library_root/0` is the source of truth; this context
  reflects and edits it. It owns library initialization and the file-moving
  primitives (relocate, quarantine) that back the organization workflow.
  """
  alias Beatgrid.{Gold, Operations, Tagging}
  alias Beatgrid.Library.{FileInfo, GenreFolders, MetadataAI, Normalize, Track, Tracks}
  alias Beatgrid.YouTube.TitleParser

  @structural_dirs ["_Inbox", "_Quarantine"]

  @import_topic "import"

  @doc "Subscribe to import-progress events (`{:import_progress, payload}`)."
  @spec subscribe_import() :: :ok | {:error, term()}
  def subscribe_import, do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, @import_topic)

  @doc "Broadcast an import-progress event (contract: `Beatgrid.Events`)."
  @spec broadcast_import(Beatgrid.Events.import_progress()) :: :ok
  def broadcast_import(payload),
    do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, @import_topic, {:import_progress, payload})

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
  Commits a reviewed import: for each `{source_path, overrides}` item, copies the
  file into `_Inbox` (skipping content-hash duplicates) and creates a track with
  the reviewed artist/title overlaid onto the file's own tags. Broadcasts
  `{:import_progress, …}` per item so the LiveView shows live progress.

  `items` is a list of string-keyed maps (Oban-arg shaped):
  `%{"source_path" => abs, "artist" => a, "title" => t}` — `artist`/`title` may be
  blank (then the file's tags stand). Returns `%{imported: n, skipped: m}`.
  """
  @spec import_files([map()], String.t(), keyword()) ::
          %{imported: non_neg_integer(), skipped: non_neg_integer()}
  def import_files(items, batch_id, _opts \\ []) do
    File.mkdir_p!(abs_path("_Inbox"))
    seen = library_hashes()
    total = length(items)

    broadcast_import(%{batch_id: batch_id, status: :running, done: 0, total: total, imported: 0})

    {summary, _seen, _done} =
      Enum.reduce(items, {%{imported: 0, skipped: 0}, seen, 0}, fn item, {acc, seen, done} ->
        {acc, seen} = import_one_override(item, acc, seen)
        done = done + 1

        broadcast_import(%{
          batch_id: batch_id,
          status: :running,
          done: done,
          total: total,
          imported: acc.imported
        })

        {acc, seen, done}
      end)

    broadcast_import(%{
      batch_id: batch_id,
      status: :done,
      done: total,
      total: total,
      imported: summary.imported,
      skipped: summary.skipped
    })

    summary
  end

  defp import_one_override(%{"source_path" => src} = item, acc, seen) do
    info = FileInfo.read(src)
    sha = info[:content_sha256]

    if is_binary(sha) and MapSet.member?(seen, sha) do
      {Map.update!(acc, :skipped, &(&1 + 1)), seen}
    else
      dest_rel = ensure_unique(Path.join("_Inbox", info.filename))
      File.cp!(src, abs_path(dest_rel))

      attrs =
        info
        |> Map.merge(%{
          rel_path: dest_rel,
          source_playlist: "import",
          status: :present,
          last_scanned_at: DateTime.truncate(DateTime.utc_now(), :second)
        })
        |> overlay_names(item)

      {:ok, _track} = Tracks.upsert_by_path(attrs)
      {Map.update!(acc, :imported, &(&1 + 1)), MapSet.put(seen, sha)}
    end
  end

  # Overlay the reviewed artist/title onto the file's tags, ignoring blanks.
  defp overlay_names(attrs, item) do
    attrs
    |> maybe_put(:tag_artist, item["artist"])
    |> maybe_put(:tag_title, item["title"])
  end

  defp maybe_put(attrs, _key, value) when value in [nil, ""], do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

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
  # Finally flag fuzzy near-dups (same artist+title as a present track) — computed
  # after refinement so AI-filled names count too, and distinct from `duplicate`
  # (the exact content-hash match).
  defp build_rows(paths, opts) do
    seen = library_hashes()
    present_sigs = Tracks.present_signatures()

    paths
    |> Enum.map(&base_row(&1, seen))
    |> refine_rows(Keyword.get(opts, :ai, true))
    |> Enum.map(&flag_near_dup(&1, present_sigs))
  end

  defp flag_near_dup(row, present_sigs) do
    sig = Tracks.signature(Normalize.normalize(row.artist), Normalize.normalize(row.title))
    Map.put(row, :near_dup, not is_nil(sig) and sig in present_sigs and not row.duplicate)
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
  Effective audio attrs for a track: the Soundcharts value, falling back to the
  locally-detected one (energy is Soundcharts-only). The track must have
  `:soundcharts_song` preloaded.
  """
  @spec effective(Track.t()) :: %{
          camelot: String.t() | nil,
          bpm: number() | nil,
          energy: float() | nil
        }
  def effective(%Track{} = track) do
    song = track.soundcharts_song

    %{
      camelot: track.camelot_manual || (song && song.camelot) || track.camelot_detected,
      bpm: track.bpm_manual || (song && song.tempo_bpm) || track.bpm_detected,
      energy: song && song.energy
    }
  end

  @doc "Estado efetivo de Ouro {bool, motivo} — fachada de UI sobre Beatgrid.Gold."
  defdelegate gold(track), to: Gold, as: :effective

  @doc "Alterna o override manual de Ouro: nil → oposto do efetivo; setado → volta a automático."
  @spec toggle_gold(Track.t()) :: {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def toggle_gold(%Track{gold_manual: nil} = track) do
    {is_gold, _} = Gold.effective(track)
    Tracks.update(track, %{gold_manual: not is_gold})
  end

  def toggle_gold(%Track{} = track), do: Tracks.update(track, %{gold_manual: nil})

  @doc "Limpa o override manual (volta ao automático)."
  @spec clear_gold_manual(Track.t()) :: {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def clear_gold_manual(%Track{} = track), do: Tracks.update(track, %{gold_manual: nil})

  @doc """
  Apaga a faixa de vez: remove o arquivo do disco e o registro. Arquivo ausente
  (`:enoent`) ainda remove o registro. Único hard-delete do app (só `/importados`).
  """
  @spec hard_delete(Track.t()) :: {:ok, Track.t()} | {:error, term()}
  def hard_delete(%Track{} = track) do
    case File.rm(abs_path(track.rel_path)) do
      :ok -> Tracks.delete(track)
      {:error, :enoent} -> Tracks.delete(track)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Moves a track directly into the genre folder `folder_key`: relocates the file,
  records an undoable `:move` operation (with the ORIGINAL `rel_path` as `from`, so
  the undo can put it back) and writes the genre ID3 tag. Returns the moved track
  and the operation's `batch_id`. Rejects an unknown folder (`:unknown_folder`) and
  a no-op move into the track's current folder (`:already_there`).
  """
  @spec move_to_folder(Track.t(), String.t()) ::
          {:ok, Track.t(), Ecto.UUID.t()} | {:error, term()}
  def move_to_folder(%Track{} = track, folder_key) do
    move_in_batch(track, folder_key, Uniq.UUID.uuid7())
  end

  @doc """
  Moves several tracks (by id) into `folder_key` under one shared `batch_id` (so a
  single "Desfazer" reverts the whole batch). Tracks that can't move — missing id,
  unknown folder, already in the folder, or a relocate error — count as `failed`.
  Returns `%{moved, failed, batch_id}`.
  """
  @spec move_many([Ecto.UUID.t()], String.t()) :: %{
          moved: non_neg_integer(),
          failed: non_neg_integer(),
          batch_id: Ecto.UUID.t()
        }
  def move_many(track_ids, folder_key) do
    batch_id = Uniq.UUID.uuid7()

    results =
      Enum.map(track_ids, fn id ->
        case Tracks.get(id) do
          %Track{} = t -> move_one_in_batch(t, folder_key, batch_id)
          _ -> :failed
        end
      end)

    %{
      moved: Enum.count(results, &(&1 == :moved)),
      failed: Enum.count(results, &(&1 == :failed)),
      batch_id: batch_id
    }
  end

  defp move_one_in_batch(track, folder_key, batch_id) do
    case move_in_batch(track, folder_key, batch_id) do
      {:ok, _moved, _batch_id} -> :moved
      {:error, _} -> :failed
    end
  end

  defp move_in_batch(%Track{} = track, folder_key, batch_id) do
    with %{dir_name: dir} <- GenreFolders.get_by_key(folder_key) || {:error, :unknown_folder},
         :ok <- ensure_not_already_there(track, folder_key),
         orig = track.rel_path,
         dest_rel = Path.join(dir, track.filename),
         {:ok, moved} <- relocate(track, dest_rel, folder_key) do
      Operations.record(%{
        track_id: track.id,
        kind: :move,
        from: orig,
        to: folder_key,
        batch_id: batch_id,
        suggestion_id: nil
      })

      Tagging.write_genre(moved)
      {:ok, moved, batch_id}
    else
      {:error, _} = e -> e
    end
  end

  defp ensure_not_already_there(%Track{genre_folder: key}, key), do: {:error, :already_there}
  defp ensure_not_already_there(_track, _folder_key), do: :ok

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
  a unique " (N)" suffix. `new_filename` must be a bare filename: any path
  component (slashes, "..", absolute paths) is rejected so a rename can never
  escape the track's directory.
  """
  @spec rename(Track.t(), String.t()) :: {:ok, Track.t()} | {:error, term()}
  def rename(track, new_filename) do
    with {:ok, safe} <- safe_filename(new_filename) do
      dest_rel = Path.join(Path.dirname(track.rel_path), safe)
      do_move(track, dest_rel, %{})
    end
  end

  # A rename target must be a bare filename. `Path.basename/1` collapses any
  # directory part to the last segment; if that differs from the input the user
  # typed a path (or "..", or a leading "/") — reject it rather than silently
  # moving the file somewhere else.
  defp safe_filename(name) do
    trimmed = String.trim(name)

    if trimmed in ["", ".", ".."] or Path.basename(trimmed) != trimmed,
      do: {:error, :invalid_filename},
      else: {:ok, trimmed}
  end

  @doc "Moves a track into `_Quarantine` and flags its status. Never deletes."
  @spec quarantine(Track.t()) :: {:ok, Track.t()} | {:error, term()}
  def quarantine(track) do
    do_move(track, Path.join("_Quarantine", track.filename), %{
      status: :quarantined,
      genre_folder: nil
    })
  end

  @doc """
  Restores a quarantined track back to `dest_rel` (its original path): moves the
  file out of `_Quarantine`, flips the status back to `:present` and recomputes
  the genre folder from the destination path. The inverse of `quarantine/1`.
  """
  @spec restore_from_quarantine(Track.t(), String.t()) :: {:ok, Track.t()} | {:error, term()}
  def restore_from_quarantine(track, dest_rel) do
    do_move(track, dest_rel, %{status: :present, genre_folder: genre_folder_for_rel(dest_rel)})
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
         :ok <- check_within_root(dest),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- File.rename(src, dest) do
      Tracks.update(
        track,
        Map.merge(extra_attrs, %{rel_path: unique_rel, filename: Path.basename(unique_rel)})
      )
    end
  end

  defp check_source(src), do: if(File.exists?(src), do: :ok, else: {:error, :source_missing})

  # Never move a file outside the managed library root, even if a caller hands us
  # a crafted destination. Compares fully-expanded paths with a trailing-separator
  # guard so a sibling dir sharing the root's prefix (".../lib-evil") can't pass.
  defp check_within_root(dest) do
    root = Path.expand(library_root())
    expanded = Path.expand(dest)

    if expanded == root or String.starts_with?(expanded, root <> "/"),
      do: :ok,
      else: {:error, :outside_root}
  end

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
