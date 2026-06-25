defmodule Beatgrid.Library.Scanner do
  @moduledoc """
  Walks a directory tree and upserts a track per audio file (reading metadata +
  quality via `FileInfo`), deriving organization fields from each file's path.
  Optionally marks tracks whose files have disappeared as `:missing`.
  """
  alias Beatgrid.Library.{FileInfo, GenreFolders, Tracks}

  @doc """
  Scans `root` for audio files and upserts a track per file.

  Options:
    * `:mark_missing` (default `false`) — mark present tracks whose files are no
      longer under `root` as `:missing`. Only meaningful for the canonical
      library root.
  """
  @spec scan(String.t(), keyword()) :: {:ok, %{scanned: non_neg_integer()}}
  def scan(root, opts \\ []) do
    root = Path.expand(root)
    folder_index = genre_folder_index()

    scanned_paths =
      root
      |> FileInfo.audio_files()
      |> Enum.map(&scan_file(&1, root, folder_index))
      |> Enum.reject(&is_nil/1)

    if Keyword.get(opts, :mark_missing, false) do
      Tracks.mark_missing_except(scanned_paths)
    end

    {:ok, %{scanned: length(scanned_paths)}}
  end

  defp scan_file(abs, root, folder_index) do
    rel_path = Path.relative_to(abs, root)
    top = rel_path |> Path.split() |> List.first()

    attrs =
      Map.merge(FileInfo.read(abs), %{
        rel_path: rel_path,
        source_playlist: top,
        genre_folder: Map.get(folder_index, top),
        status: status_for(top),
        last_scanned_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    case Tracks.upsert_by_path(attrs) do
      {:ok, track} -> track.rel_path
      {:error, _changeset} -> nil
    end
  end

  defp status_for("_Quarantine"), do: :quarantined
  defp status_for(_top), do: :present

  defp genre_folder_index do
    Map.new(GenreFolders.list(), fn folder -> {folder.dir_name, folder.key} end)
  end
end
