defmodule Beatgrid.Library.FileInfo do
  @moduledoc """
  Reads file-level + audio-metadata + quality attributes for one audio file,
  without any path-derived organization fields. Shared by the scanner and the
  importer (each adds its own `rel_path`, `source_playlist`, etc.).
  """
  alias Beatgrid.Audio
  alias Beatgrid.Library.Quality

  @audio_exts ~w(.mp3 .m4a .flac .wav .aac .ogg)

  # Containers downloaders hand out that often carry pure audio (a .mpeg that IS
  # an mp3, an .mp4 with only an aac stream). They qualify as import candidates
  # only when a probe confirms an audio stream — never by extension alone.
  @container_exts ~w(.mp4 .mpeg .mpg .mov .webm .m4v .mkv)

  @doc "Lists audio files under `root`, recursively (absolute paths)."
  @spec audio_files(String.t()) :: [String.t()]
  def audio_files(root), do: root |> walk() |> Enum.filter(&audio?/1)

  @doc """
  Lists import candidates under `root`: audio files by extension, plus container
  files (`.mp4`, `.mpeg`, …) whose probe finds an audio stream. The scanner keeps
  using `audio_files/1` — the library itself never holds lying extensions.
  """
  @spec importable_files(String.t()) :: [String.t()]
  def importable_files(root), do: root |> walk() |> Enum.filter(&importable?/1)

  @doc """
  Cheap extension-only screen: could this file be importable? Used by listings
  that must not shell out per entry; `importable?/1` adds the probe.
  """
  @spec candidate?(String.t()) :: boolean()
  def candidate?(path), do: audio?(path) or container?(path)

  @spec importable?(String.t()) :: boolean()
  def importable?(path), do: audio?(path) or (container?(path) and probed_audio?(path))

  @spec audio?(String.t()) :: boolean()
  def audio?(path), do: String.downcase(Path.extname(path)) in @audio_exts

  defp container?(path), do: String.downcase(Path.extname(path)) in @container_exts

  defp probed_audio?(path), do: match?({:ok, _metadata}, Audio.read_metadata(path))

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
    |> resolve_format(metadata)
  end

  @doc """
  The extension the file SHOULD have for its (probed) format — `nil` when the
  current one already tells the truth or the format is unknown. The importer
  uses this so a `.mpeg` that is an mp3 lands in the library as `.mp3`.
  """
  @spec corrective_ext(map()) :: String.t() | nil
  def corrective_ext(%{filename: filename, format: format}) do
    ext = canonical_ext(format)
    if ext && String.downcase(Path.extname(filename)) != ext, do: ext, else: nil
  end

  defp canonical_ext(:mp3), do: ".mp3"
  defp canonical_ext(:m4a), do: ".m4a"
  defp canonical_ext(:flac), do: ".flac"
  defp canonical_ext(:wav), do: ".wav"
  defp canonical_ext(:aac), do: ".aac"
  defp canonical_ext(:ogg), do: ".ogg"
  defp canonical_ext(:other), do: nil

  # A container extension says nothing about the audio inside; the probed
  # `format_name` does ("mp3", "mov,mp4,m4a,3gp,3g2,mj2", …).
  defp resolve_format(%{format: :other} = attrs, {:ok, %{format_name: name}})
       when is_binary(name),
       do: %{attrs | format: format_from_name(name)}

  defp resolve_format(attrs, _metadata), do: attrs

  # ffprobe's `format_name` is a comma-joined demuxer list — first marker wins.
  @format_markers [
    {"mp3", :mp3},
    {"mp4", :m4a},
    {"m4a", :m4a},
    {"mov", :m4a},
    {"flac", :flac},
    {"ogg", :ogg},
    {"wav", :wav},
    {"aac", :aac},
    {"adts", :aac}
  ]

  defp format_from_name(name) do
    Enum.find_value(@format_markers, :other, fn {marker, format} ->
      name =~ marker && format
    end)
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
