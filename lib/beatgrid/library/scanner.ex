defmodule Beatgrid.Library.Scanner do
  @moduledoc """
  Walks a directory tree, reads each audio file's metadata via the `Beatgrid.Audio`
  port, detects quality issues, and upserts a track per file. Optionally marks
  tracks whose files have disappeared as `:missing`.
  """
  alias Beatgrid.Audio
  alias Beatgrid.Library.{GenreFolders, Quality, Tracks}

  @audio_exts ~w(.mp3 .m4a .flac .wav .aac .ogg)

  @doc """
  Scans `root` for audio files and upserts a track per file.

  Options:
    * `:mark_missing` (default `false`) — mark present tracks whose files are
      no longer under `root` as `:missing`. Only meaningful for the canonical
      library root, not for ad-hoc scans of other directories.
  """
  @spec scan(String.t(), keyword()) :: {:ok, %{scanned: non_neg_integer()}}
  def scan(root, opts \\ []) do
    root = Path.expand(root)
    folder_index = genre_folder_index()

    scanned_paths =
      root
      |> audio_files()
      |> Enum.map(&scan_file(&1, root, folder_index))
      |> Enum.reject(&is_nil/1)

    if Keyword.get(opts, :mark_missing, false) do
      Tracks.mark_missing_except(scanned_paths)
    end

    {:ok, %{scanned: length(scanned_paths)}}
  end

  defp scan_file(abs, root, folder_index) do
    case Tracks.upsert_by_path(build_attrs(abs, root, folder_index)) do
      {:ok, track} -> track.rel_path
      {:error, _changeset} -> nil
    end
  end

  defp build_attrs(abs, root, folder_index) do
    rel_path = Path.relative_to(abs, root)
    top = rel_path |> Path.split() |> List.first()
    metadata = Audio.read_metadata(abs)

    %{
      rel_path: rel_path,
      filename: Path.basename(abs),
      format: format_from_ext(abs),
      file_size_bytes: file_size(abs),
      content_sha256: sha256(abs),
      source_playlist: top,
      genre_folder: Map.get(folder_index, top),
      status: status_for(top),
      quality_issues: Quality.detect(metadata),
      last_scanned_at: DateTime.truncate(DateTime.utc_now(), :second)
    }
    |> merge_metadata(metadata)
  end

  defp merge_metadata(attrs, {:ok, m}) do
    Map.merge(attrs, %{
      bitrate_kbps: m.bitrate_kbps,
      sample_rate_hz: m.sample_rate_hz,
      channels: m.channels,
      duration_ms: m.duration_ms,
      tag_title: m.title,
      tag_artist: m.artist,
      tag_album: m.album,
      tag_album_artist: m.album_artist,
      tag_year: m.year,
      tag_track_no: m.track_no,
      tag_isrc: m.isrc,
      tag_genre: m.genre,
      tag_comment: m.comment,
      raw_tags: m.raw_tags
    })
  end

  defp merge_metadata(attrs, {:error, _reason}), do: attrs

  defp audio_files(root), do: root |> walk() |> Enum.filter(&audio?/1)

  defp walk(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &classify(Path.join(dir, &1)))
      {:error, _reason} -> []
    end
  end

  defp classify(path) do
    cond do
      File.dir?(path) -> walk(path)
      File.regular?(path) -> [path]
      true -> []
    end
  end

  defp audio?(path), do: String.downcase(Path.extname(path)) in @audio_exts

  defp format_from_ext(path) do
    case String.downcase(Path.extname(path)) do
      ".mp3" -> :mp3
      ".m4a" -> :m4a
      ".flac" -> :flac
      ".wav" -> :wav
      ".aac" -> :aac
      ".ogg" -> :ogg
      _ -> :other
    end
  end

  defp status_for("_Quarantine"), do: :quarantined
  defp status_for(_top), do: :present

  defp file_size(abs) do
    case File.stat(abs) do
      {:ok, %{size: size}} -> size
      {:error, _reason} -> nil
    end
  end

  defp sha256(abs) do
    case File.read(abs) do
      {:ok, binary} -> :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
      {:error, _reason} -> nil
    end
  end

  defp genre_folder_index do
    Map.new(GenreFolders.list(), fn folder -> {folder.dir_name, folder.key} end)
  end
end
