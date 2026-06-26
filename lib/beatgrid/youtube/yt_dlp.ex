defmodule Beatgrid.YouTube.YtDlp do
  @moduledoc """
  Downloader adapter backed by the `yt-dlp` CLI. Extracts audio to mp3 into the
  destination dir and `--print`s one `id<TAB>title<TAB>url` line per track (a
  playlist URL expands to many), from which we derive each file's path.

  Same hardening as the other CLI adapters: stdin from `/dev/null` (so it can't
  block waiting for input) and a generous timeout (downloads are legitimately long).
  """
  @behaviour Beatgrid.YouTube.Downloader

  @sep "\t"
  # 10 min: a playlist of several tracks can take a while.
  @default_timeout_ms 600_000

  @impl Beatgrid.YouTube.Downloader
  def download(url, dest_dir) do
    File.mkdir_p!(dest_dir)
    template = Path.join(dest_dir, "%(id)s.%(ext)s")

    cli_args = [
      "-x",
      "--audio-format",
      "mp3",
      "--no-overwrites",
      "--print",
      "after_move:%(id)s#{@sep}%(title)s#{@sep}%(webpage_url)s",
      "-o",
      template,
      url
    ]

    argv = ["-c", ~s|exec "$@" < /dev/null|, "sh", executable() | cli_args]

    case run(fn -> System.cmd("/bin/sh", argv, stderr_to_stdout: false) end) do
      {:ok, {out, 0}} -> {:ok, parse(out, dest_dir)}
      {:ok, {out, code}} -> {:error, {:yt_dlp_exit, code, String.slice(out, 0, 500)}}
      {:exit, reason} -> {:error, {:yt_dlp_exception, inspect(reason)}}
      nil -> {:error, :timeout}
    end
  end

  @doc "Parses yt-dlp's tab-separated `--print` lines into downloader items."
  @spec parse(String.t(), String.t()) :: [Beatgrid.YouTube.Downloader.item()]
  def parse(output, dest_dir) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, @sep) do
        [id, title, url] -> [%{path: Path.join(dest_dir, id <> ".mp3"), title: title, url: url}]
        _ -> []
      end
    end)
  end

  defp run(fun) do
    task = Task.async(fun)
    Task.yield(task, timeout()) || Task.shutdown(task, :brutal_kill)
  end

  defp executable, do: config()[:executable] || "yt-dlp"
  defp timeout, do: config()[:timeout_ms] || @default_timeout_ms
  defp config, do: Application.get_env(:beatgrid, __MODULE__, [])
end
