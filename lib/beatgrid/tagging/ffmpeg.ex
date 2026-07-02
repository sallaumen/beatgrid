defmodule Beatgrid.Tagging.Ffmpeg do
  @moduledoc """
  Tagging adapter backed by `ffmpeg`. Writes the ID3 genre with a stream copy
  (`-c copy`, no re-encode) into a sibling temp file, then atomically replaces the
  original. The audio bytes are untouched — only the metadata changes — and a
  failed write leaves the original intact.
  """
  @behaviour Beatgrid.Tagging.Writer

  alias Beatgrid.Cli

  # A stream copy is fast even for large files; a minute is generous headroom.
  @default_timeout_ms 60_000

  @impl Beatgrid.Tagging.Writer
  def write_genre(path, genre) do
    tmp = Path.join(Path.dirname(path), ".tagging-" <> Path.basename(path))

    args = ["-y", "-i", path, "-map", "0", "-c", "copy", "-metadata", "genre=#{genre}", tmp]

    case Cli.run(fn -> System.cmd(executable(), args, stderr_to_stdout: true) end, timeout()) do
      {:ok, {_out, 0}} ->
        File.rename(tmp, path)

      {:ok, {out, code}} ->
        File.rm(tmp)
        {:error, {:ffmpeg_exit, code, String.slice(out, 0, 500)}}

      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  rescue
    error -> {:error, {:ffmpeg_exception, Exception.message(error)}}
  end

  defp executable, do: config()[:executable] || "ffmpeg"
  defp timeout, do: config()[:timeout_ms] || @default_timeout_ms
  defp config, do: Application.get_env(:beatgrid, __MODULE__, [])
end
