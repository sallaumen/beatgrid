defmodule Beatgrid.Audio.GainApplierCli do
  @moduledoc """
  Applies loudness gain to files using the safest available local tool.

  MP3 files use `mp3gain` when available, which is lossless and reversible. Other
  files, and MP3 files without `mp3gain`, use `ffmpeg` with a sibling temp file
  and an atomic rename after a successful non-empty output.
  """
  @behaviour Beatgrid.Audio.GainApplier

  require Logger

  alias Beatgrid.Audio.Ffprobe
  alias Beatgrid.Cli

  @mp3gain_step_db 1.5
  # A re-encode of one track runs well under a minute; two is generous headroom.
  @default_timeout_ms 120_000

  @impl true
  def apply(path, gain_db) when is_binary(path) and is_number(gain_db) do
    case String.downcase(Path.extname(path)) do
      ".mp3" -> apply_mp3(path, gain_db)
      ext -> apply_ffmpeg(path, gain_db, ext)
    end
  end

  @doc "Converts a dB gain into mp3gain's 1.5 dB step count."
  @spec mp3gain_steps(number()) :: integer()
  def mp3gain_steps(gain_db), do: round(gain_db / @mp3gain_step_db)

  defp apply_mp3(path, gain_db) do
    case System.find_executable("mp3gain") do
      nil ->
        Logger.warning("mp3gain not found; falling back to ffmpeg re-encode for #{path}")
        apply_ffmpeg(path, gain_db, ".mp3")

      _mp3gain ->
        steps = mp3gain_steps(gain_db)

        if steps == 0, do: :ok, else: run_mp3gain(path, steps)
    end
  rescue
    error -> {:error, {:mp3gain_exception, Exception.message(error)}}
  end

  defp run_mp3gain(path, steps) do
    args = ["-q", "-p", "-g", to_string(steps), path]

    case Cli.run(fn -> System.cmd("mp3gain", args, stderr_to_stdout: true) end, timeout()) do
      {:ok, {_out, 0}} -> :ok
      {:ok, {out, code}} -> {:error, {:mp3gain_exit, code, String.slice(out, 0, 500)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_ffmpeg(path, gain_db, ext) do
    tmp = Path.join(Path.dirname(path), ".gain-" <> Path.basename(path))

    with :ok <- ensure_ffmpeg(),
         true <- File.regular?(path) || {:error, :enoent},
         {:ok, args} <- ffmpeg_args(path, tmp, gain_db, ext),
         {:ok, {_out, 0}} <- run_ffmpeg(args),
         :ok <- non_empty_file(tmp),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(tmp)
        error

      {:ok, {out, code}} ->
        File.rm(tmp)
        {:error, {:ffmpeg_exit, code, String.slice(out, 0, 500)}}

      false ->
        File.rm(tmp)
        {:error, :enoent}
    end
  rescue
    error ->
      {:error, {:ffmpeg_exception, Exception.message(error)}}
  end

  defp run_ffmpeg(args) do
    Cli.run(fn -> System.cmd("ffmpeg", args, stderr_to_stdout: true) end, timeout())
  end

  defp ensure_ffmpeg do
    if System.find_executable("ffmpeg"), do: :ok, else: {:error, :ffmpeg_not_found}
  end

  defp timeout do
    Application.get_env(:beatgrid, __MODULE__, [])[:timeout_ms] || @default_timeout_ms
  end

  defp ffmpeg_args(path, tmp, gain_db, ext) do
    with {:ok, metadata} <- Ffprobe.read_metadata(path),
         {:ok, codec} <- codec_for(ext) do
      args =
        [
          "-y",
          "-hide_banner",
          "-nostats",
          "-threads",
          "1",
          "-i",
          path,
          "-af",
          "volume=#{gain_db}dB",
          "-map",
          "0",
          "-map_metadata",
          "0",
          "-c:v",
          "copy",
          "-c:a",
          codec
        ]
        |> maybe_bitrate(metadata.bitrate_kbps, ext)

      {:ok, args ++ [tmp]}
    end
  end

  defp codec_for(".mp3"), do: {:ok, "libmp3lame"}
  defp codec_for(".m4a"), do: {:ok, "aac"}
  defp codec_for(".aac"), do: {:ok, "aac"}
  defp codec_for(".ogg"), do: {:ok, "libvorbis"}
  defp codec_for(".flac"), do: {:ok, "flac"}
  defp codec_for(".wav"), do: {:ok, "pcm_s16le"}
  defp codec_for(_ext), do: {:error, :unsupported_format}

  defp maybe_bitrate(args, bitrate_kbps, ext)
       when ext in [".mp3", ".m4a", ".aac", ".ogg"] and is_integer(bitrate_kbps) and
              bitrate_kbps > 0,
       do: args ++ ["-b:a", "#{bitrate_kbps}k"]

  defp maybe_bitrate(args, _bitrate_kbps, _ext), do: args

  defp non_empty_file(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 -> :ok
      _ -> {:error, :empty_output}
    end
  end
end
