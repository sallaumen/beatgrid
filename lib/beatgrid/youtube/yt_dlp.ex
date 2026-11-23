defmodule Beatgrid.YouTube.YtDlp do
  @moduledoc """
  Downloader adapter backed by the `yt-dlp` CLI. Extracts audio to mp3 into the
  destination dir and `--print`s one `id<TAB>title<TAB>url` line per track (a
  single confirmed video), from which we derive the file path.

  Same hardening as the other CLI adapters: stdin from `/dev/null` (so it can't
  block waiting for input) and a generous timeout (downloads are legitimately long).
  """
  @behaviour Beatgrid.YouTube.Downloader

  alias Beatgrid.Cli
  alias Beatgrid.YouTube.Link
  alias Beatgrid.YtDlpError

  @sep "\t"
  # 10 min: a playlist of several tracks can take a while.
  @default_timeout_ms 600_000
  # Listing is metadata-only (no download) — a short timeout is plenty.
  @list_timeout_ms 60_000

  @impl Beatgrid.YouTube.Downloader
  def download(url, dest_dir) do
    case Link.parse(url) do
      {:video, _} = video -> download_video(Link.url(video), dest_dir)
      _ -> invalid_link()
    end
  end

  defp invalid_link,
    do:
      {:error,
       Beatgrid.Error.new(:invalid_link, "O download precisa de um link de vídeo do YouTube.")}

  defp download_video(url, dest_dir) do
    with :ok <- File.mkdir_p(dest_dir), do: extract(url, dest_dir)
  end

  defp extract(url, dest_dir) do
    template = Path.join(dest_dir, "%(id)s.%(ext)s")

    cli_args = [
      "--no-playlist",
      "-x",
      "--audio-format",
      "mp3",
      "--no-overwrites",
      "--print",
      "after_move:%(id)s#{@sep}%(title)s#{@sep}%(webpage_url)s#{@sep}%(view_count)s#{@sep}%(upload_date)s",
      "-o",
      template,
      "--",
      url
    ]

    argv = ["-c", ~s|exec "$@" < /dev/null|, "sh", executable() | cli_args]

    case Cli.run(fn -> System.cmd("/bin/sh", argv, stderr_to_stdout: true) end, timeout()) do
      {:ok, {out, 0}} ->
        {:ok, parse(out, dest_dir)}

      {:ok, {out, code}} ->
        {:error, YtDlpError.from_exit(code, out)}

      {:error, {:exit, reason}} ->
        {:error, {:yt_dlp_exception, inspect(reason)}}

      {:error, :timeout} ->
        {:error, :timeout}
    end
  end

  @impl Beatgrid.YouTube.Downloader
  def list_entries(url) do
    case Link.parse(url) do
      {:video, id} -> list_video(id)
      {:playlist, _} = playlist -> list_cli(Link.url(playlist))
      _ -> list_search(url)
    end
  end

  # oEmbed supplies the public title even when YouTube is throttling audio extraction.
  defp list_video(id) do
    url = Link.url({:video, id})

    case Req.get("https://www.youtube.com/oembed",
           params: [url: url, format: "json"],
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: %{"title" => title}}} when is_binary(title) ->
        {:ok, [%{id: id, title: title, url: url, playlist_title: nil}]}

      _ ->
        list_cli(url)
    end
  end

  defp list_search("ytsearch1:" <> query) when query != "", do: list_cli("ytsearch1:" <> query)
  defp list_search("ytsearch3:" <> query) when query != "", do: list_cli("ytsearch3:" <> query)
  defp list_search(_), do: invalid_link()

  defp list_cli(url) do
    cli_args = [
      "--flat-playlist",
      "--print",
      "%(id)s#{@sep}%(title)s#{@sep}%(webpage_url)s#{@sep}%(playlist_title)s",
      "--",
      url
    ]

    argv = ["-c", ~s|exec "$@" < /dev/null|, "sh", executable() | cli_args]

    case Cli.run(fn -> System.cmd("/bin/sh", argv, stderr_to_stdout: true) end, @list_timeout_ms) do
      {:ok, {out, 0}} ->
        {:ok, parse_entries(out)}

      {:ok, {out, code}} ->
        {:error, YtDlpError.from_exit(code, out)}

      {:error, {:exit, reason}} ->
        {:error, {:yt_dlp_exception, inspect(reason)}}

      {:error, :timeout} ->
        {:error, :timeout}
    end
  end

  @doc """
  Parses yt-dlp's `--flat-playlist` tab lines into entries (one per video). The
  4th column is the playlist title (`"NA"` for a single video); legacy 3-column
  lines degrade to a nil title.
  """
  @spec parse_entries(String.t()) :: [Beatgrid.YouTube.Downloader.entry()]
  def parse_entries(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, @sep) do
        [id, title, url, playlist_title] ->
          [entry(id, title, url, nil_if_na(playlist_title))]

        [id, title, url] ->
          [entry(id, title, url, nil)]

        _ ->
          []
      end
    end)
  end

  defp entry(id, title, url, playlist_title),
    do: %{id: id, title: title, url: entry_url(id, url), playlist_title: playlist_title}

  defp entry_url(id, url) do
    if URI.parse(url).host in ~w(www.youtube.com youtube.com youtu.be m.youtube.com music.youtube.com),
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

  defp executable, do: config()[:executable] || Cli.yt_dlp()
  defp timeout, do: config()[:timeout_ms] || @default_timeout_ms
  defp config, do: Application.get_env(:beatgrid, __MODULE__, [])
end
