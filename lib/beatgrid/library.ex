defmodule Beatgrid.Library do
  @moduledoc """
  The Library context — the librarian over the on-disk music collection.

  The filesystem under `library_root/0` is the source of truth; this context
  reflects and edits it. It owns library initialization and the file-moving
  primitives (relocate, quarantine) that back the organization workflow.
  """
  alias Beatgrid.Library.{GenreFolders, Track, Tracks}

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
  Moves a track's file to `dest_rel` (relative to the library root) and updates
  the row's `rel_path` and `genre_folder`. Never overwrites an existing file —
  a colliding destination gets a unique " (N)" suffix.
  """
  @spec relocate(Track.t(), String.t(), String.t() | nil) :: {:ok, Track.t()} | {:error, term()}
  def relocate(track, dest_rel, genre_folder) do
    do_move(track, dest_rel, %{genre_folder: genre_folder})
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
      Tracks.update(track, Map.put(extra_attrs, :rel_path, unique_rel))
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
end
