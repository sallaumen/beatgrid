defmodule Beatgrid.Library.Scanner do
  @moduledoc """
  Walks a directory tree and upserts a track per audio file (reading metadata +
  quality via `FileInfo`), deriving organization fields from each file's path.
  Optionally marks tracks whose files have disappeared as `:missing`.
  """
  alias Beatgrid.Error
  alias Beatgrid.Library.{FileInfo, GenreFolders, Tracks}

  @doc """
  Scans `root` for audio files and upserts a track per file.

  Options:
    * `:mark_missing` (default `false`) — mark present tracks whose files are no
      longer under `root` as `:missing`. Only meaningful for the canonical
      library root.
  """
  @spec scan(String.t(), keyword()) :: {:ok, %{scanned: non_neg_integer()}} | {:error, Error.t()}
  def scan(root, opts \\ []) do
    root = Path.expand(root)
    folder_index = genre_folder_index()

    with {:ok, files} <- FileInfo.library_audio_files(root),
         {:ok, scanned_paths} <- scan_files(files, root, folder_index) do
      if Keyword.get(opts, :mark_missing, false), do: Tracks.mark_missing_except(scanned_paths)
      {:ok, %{scanned: length(scanned_paths)}}
    end
  end

  defp scan_files(files, root, folder_index) do
    Enum.reduce_while(files, {:ok, []}, fn path, {:ok, paths} ->
      case scan_file(path, root, folder_index) do
        {:ok, track} ->
          {:cont, {:ok, [track.rel_path | paths]}}

        {:error, changeset} ->
          details = %{path: path, errors: changeset.errors}
          {:halt, {:error, Error.new(:scan_track_failed, "Cannot update scanned track", details)}}
      end
    end)
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

    case Tracks.get_by_path(rel_path) do
      nil -> Tracks.upsert_by_path(attrs)
      track -> Tracks.update(track, preserve_catalogue_fields(attrs, track))
    end
  end

  @editable_tags %{
    "artist" => :tag_artist,
    "title" => :tag_title,
    "album" => :tag_album,
    "genre" => :tag_genre,
    "year" => :tag_year
  }

  defp preserve_catalogue_fields(attrs, track) do
    edited = Map.take(@editable_tags, track.manual_fields || [])

    attrs
    |> Map.put(:source_playlist, track.source_playlist || attrs.source_playlist)
    |> preserve_import(track)
    |> Map.drop(Map.values(edited))
  end

  # Reviewed credits, playlist membership and mix cut ranges live in the catalogue.
  defp preserve_import(attrs, %{source_playlist: source} = previous)
       when source in ["youtube", "import", "recorte"] do
    provenance =
      Map.filter(previous.raw_tags || %{}, fn {key, _} ->
        String.starts_with?(key, ["youtube_", "recorte_"])
      end)

    Map.merge(attrs, %{
      tag_title: previous.tag_title || attrs[:tag_title],
      tag_artist: previous.tag_artist || attrs[:tag_artist],
      raw_tags: Map.merge(attrs[:raw_tags] || previous.raw_tags || %{}, provenance)
    })
  end

  defp preserve_import(attrs, _), do: attrs

  defp status_for("_Quarantine"), do: :quarantined
  defp status_for(_top), do: :present

  defp genre_folder_index do
    Map.new(GenreFolders.list(), fn folder -> {folder.dir_name, folder.key} end)
  end
end
