defmodule Beatgrid.Audio.MixCutterCli do
  @moduledoc """
  ffmpeg-backed `MixCutter`: stream-copies the mp3 frames of the range — no
  re-encode, no quality loss, near-instant — into a tmp file in the destination
  folder, tags artist/title (ID3v2.3), and renames into place only on success.
  `-ss` + `-t` (duration) because `-to` changes meaning under input seeking.
  """
  @behaviour Beatgrid.Audio.MixCutter

  alias Beatgrid.Cli

  @timeout_ms 60_000

  @impl Beatgrid.Audio.MixCutter
  def cut(src, dest, opts) do
    start_ms = Keyword.fetch!(opts, :start_ms)
    duration_ms = Keyword.fetch!(opts, :end_ms) - start_ms
    tmp = dest <> ".cutting.mp3"

    args = [
      ["-v", "error", "-nostdin", "-y"],
      ["-ss", ms_to_s(start_ms), "-t", ms_to_s(duration_ms)],
      ["-i", src, "-map", "0:a", "-c", "copy"],
      ["-metadata", "artist=#{Keyword.get(opts, :artist, "")}"],
      ["-metadata", "title=#{Keyword.get(opts, :title, "")}"],
      ["-id3v2_version", "3", tmp]
    ]

    run = fn -> System.cmd("ffmpeg", List.flatten(args), stderr_to_stdout: true) end

    case Cli.run(run, @timeout_ms) do
      {:ok, {_out, 0}} -> seal(tmp, dest)
      {:ok, {out, code}} -> cleanup(tmp, {:cut_exit, code, String.slice(out, 0, 300)})
      {:error, reason} -> cleanup(tmp, reason)
    end
  end

  defp ms_to_s(ms), do: Float.to_string(ms / 1000)

  defp seal(tmp, dest) do
    case File.stat(tmp) do
      {:ok, %{size: size}} when size > 0 -> File.rename(tmp, dest)
      _empty_or_missing -> cleanup(tmp, :empty_cut)
    end
  end

  defp cleanup(tmp, reason) do
    File.rm(tmp)
    {:error, reason}
  end
end
