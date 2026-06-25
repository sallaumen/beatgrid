defmodule Beatgrid.Tagging.Ffmpeg do
  @moduledoc """
  Tagging adapter backed by `ffmpeg`. Writes the ID3 genre with a stream copy
  (`-c copy`, no re-encode) into a sibling temp file, then atomically replaces the
  original. The audio bytes are untouched — only the metadata changes — and a
  failed write leaves the original intact.
  """
  @behaviour Beatgrid.Tagging.Writer

  @impl Beatgrid.Tagging.Writer
  def write_genre(path, genre) do
    tmp = Path.join(Path.dirname(path), ".tagging-" <> Path.basename(path))

    args = ["-y", "-i", path, "-map", "0", "-c", "copy", "-metadata", "genre=#{genre}", tmp]

    case System.cmd(executable(), args, stderr_to_stdout: true) do
      {_out, 0} ->
        File.rename(tmp, path)

      {out, code} ->
        File.rm(tmp)
        {:error, {:ffmpeg_exit, code, String.slice(out, 0, 500)}}
    end
  rescue
    error -> {:error, {:ffmpeg_exception, Exception.message(error)}}
  end

  defp executable, do: Application.get_env(:beatgrid, __MODULE__, [])[:executable] || "ffmpeg"
end
