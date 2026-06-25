defmodule Beatgrid.Library.FileInfo do
  @moduledoc """
  Reads file-level + audio-metadata + quality attributes for one audio file,
  without any path-derived organization fields. Shared by the scanner and the
  importer (each adds its own `rel_path`, `source_playlist`, etc.).
  """
  alias Beatgrid.Audio
  alias Beatgrid.Library.Quality

  @audio_exts ~w(.mp3 .m4a .flac .wav .aac .ogg)

  @doc "Lists audio files under `root`, recursively (absolute paths)."
  @spec audio_files(String.t()) :: [String.t()]
  def audio_files(root), do: root |> walk() |> Enum.filter(&audio?/1)

  @spec audio?(String.t()) :: boolean()
  def audio?(path), do: String.downcase(Path.extname(path)) in @audio_exts

  @doc "Attributes for one file: identity, audio properties, tags, and quality issues."
  @spec read(String.t()) :: map()
  def read(abs) do
    metadata = Audio.read_metadata(abs)

    %{
      filename: Path.basename(abs),
      format: format_from_ext(abs),
      file_size_bytes: file_size(abs),
      content_sha256: sha256(abs),
      quality_issues: Quality.detect(metadata)
    }
    |> merge_metadata(metadata)
  end

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
end
