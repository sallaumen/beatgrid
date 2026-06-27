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
  # Listing is metadata-only (no download) — a short timeout is plenty.
  @list_timeout_ms 60_000
  # How much of yt-dlp's output to keep in an error (enough to include the real ERROR line).
  @error_excerpt 1_000

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
      "after_move:%(id)s#{@sep}%(title)s#{@sep}%(webpage_url)s#{@sep}%(view_count)s#{@sep}%(upload_date)s",
      "-o",
      template,
      url
    ]

    argv = ["-c", ~s|exec "$@" < /dev/null|, "sh", executable() | cli_args]

    case run(fn -> System.cmd("/bin/sh", argv, stderr_to_stdout: true) end, timeout()) do
      {:ok, {out, 0}} -> {:ok, parse(out, dest_dir)}
      {:ok, {out, code}} -> {:error, {:yt_dlp_exit, code, String.slice(out, 0, @error_excerpt)}}
      {:exit, reason} -> {:error, {:yt_dlp_exception, inspect(reason)}}
      nil -> {:error, :timeout}
    end
  end

  @impl Beatgrid.YouTube.Downloader
  def list_entries(url) do
    cli_args = ["--flat-playlist", "--print", "%(id)s#{@sep}%(title)s#{@sep}%(url)s", url]
    argv = ["-c", ~s|exec "$@" < /dev/null|, "sh", executable() | cli_args]

    case run(fn -> System.cmd("/bin/sh", argv, stderr_to_stdout: true) end, @list_timeout_ms) do
      {:ok, {out, 0}} -> {:ok, parse_entries(out)}
      {:ok, {out, code}} -> {:error, {:yt_dlp_exit, code, String.slice(out, 0, @error_excerpt)}}
      {:exit, reason} -> {:error, {:yt_dlp_exception, inspect(reason)}}
      nil -> {:error, :timeout}
    end
  end

  @doc "Parses yt-dlp's `--flat-playlist` tab lines into entries (one per video)."
  @spec parse_entries(String.t()) :: [Beatgrid.YouTube.Downloader.entry()]
  def parse_entries(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, @sep) do
        [id, title, url] -> [%{id: id, title: title, url: entry_url(id, url)}]
        _ -> []
      end
    end)
  end

  defp entry_url(id, url) do
    if String.starts_with?(url, "http"),
      do: url,
      else: "https://www.youtube.com/watch?v=#{id}"
  end

  @doc "Parses yt-dlp's tab-separated `--print` lines into downloader items."
  @spec parse(String.t(), String.t()) :: [Beatgrid.YouTube.Downloader.item()]
  def parse(output, dest_dir) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, @sep) do
        [id, title, url, views, upload] ->
          [item(dest_dir, id, title, url, to_int(views), nil_if_na(upload))]

        [id, title, url] ->
          [item(dest_dir, id, title, url, nil, nil)]

        _ ->
          []
      end
    end)
  end

  defp item(dest_dir, id, title, url, views, upload) do
    %{
      path: Path.join(dest_dir, id <> ".mp3"),
      title: title,
      url: url,
      views: views,
      upload_date: upload
    }
  end

  defp to_int(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp nil_if_na(s) do
    case String.trim(s) do
      "" -> nil
      "NA" -> nil
      v -> v
    end
  end

  defp run(fun, timeout) do
    task = Task.async(fun)
    Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)
  end

  defp executable, do: config()[:executable] || "yt-dlp"
  defp timeout, do: config()[:timeout_ms] || @default_timeout_ms
  defp config, do: Application.get_env(:beatgrid, __MODULE__, [])
end
