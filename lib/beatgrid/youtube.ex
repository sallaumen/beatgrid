defmodule Beatgrid.YouTube do
  @moduledoc """
  YouTube ingestion. Downloads audio (one video or a whole playlist) into `_Inbox`
  and creates a `Track` per file with a best-effort artist/title from the video
  title — **offline**, spending no metadata-API quota. Enrichment (resolving against
  Soundcharts, proposing renames/classifications) is a separate, explicit step.

  Downloads run as background `DownloadWorker` jobs; the screen follows progress via
  the `"youtube"` PubSub topic.
  """
  alias Beatgrid.{AI, Library, Soundcharts}
  alias Beatgrid.Library.{FileInfo, NameSync, Tracks}
  alias Beatgrid.Workers.{DownloadWorker, ExpandWorker}
  alias Beatgrid.YouTube.TitleParser

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.YouTube.Downloader, :adapter],
             Beatgrid.YouTube.YtDlp
           )

  @topic "youtube"

  @doc "Subscribe to download-progress ticks."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, @topic)

  @doc "Broadcast a `{:youtube_tick}` after a download finishes."
  @spec broadcast_tick() :: :ok
  def broadcast_tick, do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, @topic, {:youtube_tick})

  @doc "Count of tracks downloaded but not yet enriched (present, unresolved, unfiled)."
  @spec pending_count() :: non_neg_integer()
  def pending_count, do: Tracks.count(status: :present, resolved: false, genre_folder: nil)

  @doc "Enqueues one `DownloadWorker` per non-blank URL (lines or a list). Returns `{:ok, count}`."
  @spec enqueue(String.t() | [String.t()]) :: {:ok, non_neg_integer()}
  def enqueue(urls) when is_binary(urls), do: urls |> String.split("\n") |> enqueue()

  def enqueue(urls) when is_list(urls) do
    urls = urls |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    Enum.each(urls, fn url -> %{url: url} |> ExpandWorker.new() |> Oban.insert() end)
    {:ok, length(urls)}
  end

  @doc """
  Lists a submitted URL's videos and enqueues one `DownloadWorker` per video,
  tagging each with the source playlist URL (when the URL expands to many).
  Returns `{:ok, video_count}` or the downloader's `{:error, reason}`.
  """
  @spec expand_and_enqueue(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def expand_and_enqueue(url) do
    with {:ok, entries} <- @adapter.list_entries(url) do
      playlist_url = if length(entries) > 1, do: url, else: nil

      Enum.each(entries, fn e ->
        %{url: e.url, video_id: e.id, title: e.title, playlist_url: playlist_url}
        |> DownloadWorker.new()
        |> Oban.insert()
      end)

      broadcast_tick()
      {:ok, length(entries)}
    end
  end

  @doc """
  Downloads a URL (video or playlist) and ingests each resulting file into `_Inbox`.
  Returns `{:ok, ingested_count}` or the downloader's `{:error, reason}`.
  """
  @spec download_and_ingest(String.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def download_and_ingest(url, playlist_url \\ nil) do
    dest = Path.join(Library.library_root(), "_Inbox")

    with {:ok, items} <- @adapter.download(url, dest) do
      ingested = items |> Enum.map(&ingest(&1, playlist_url)) |> Enum.count(&match?({:ok, _}, &1))
      {:ok, ingested}
    end
  end

  @doc """
  Enriches every pending (downloaded-but-unfiled) track: refines ambiguous titles
  with the AI, resolves each against Soundcharts (the only quota-spending step),
  then proposes renames + AI classifications so they land in the Central de Revisão.
  Returns `{:ok, %{enriched: n, resolved: m}}`.
  """
  @spec enrich_pending() :: {:ok, %{enriched: non_neg_integer(), resolved: non_neg_integer()}}
  def enrich_pending do
    ids = pending_ids()

    refine_titles(ids)
    Enum.each(ids, fn id -> id |> Tracks.get() |> Soundcharts.resolve_track() end)
    Enum.each(ids, &repropose_if_matched/1)
    AI.reclassify(tracks: Enum.map(ids, &Tracks.get/1))

    resolved = Enum.count(ids, &(Tracks.get(&1).soundcharts_song_id != nil))
    {:ok, %{enriched: length(ids), resolved: resolved}}
  end

  defp pending_ids do
    [status: :present, resolved: false, genre_folder: nil]
    |> Tracks.list_by()
    |> Enum.map(& &1.id)
  end

  # Ask the AI to extract artist/title for tracks the heuristic couldn't split.
  defp refine_titles(ids) do
    ambiguous = ids |> Enum.map(&Tracks.get/1) |> Enum.filter(&ambiguous?/1)

    with [_ | _] <- ambiguous,
         {:ok, parsed} <- AI.parse_titles(Enum.map(ambiguous, &raw_title/1)) do
      ambiguous
      |> Enum.zip(parsed)
      |> Enum.each(fn {t, p} -> Tracks.update(t, %{tag_artist: p.artist, tag_title: p.title}) end)
    end

    :ok
  end

  defp ambiguous?(track), do: is_nil(track.tag_artist) and is_binary(raw_title(track))
  defp raw_title(track), do: (track.raw_tags || %{})["youtube_title"] || track.tag_title

  defp repropose_if_matched(id) do
    track = Tracks.get_with_song(id)
    if track && track.soundcharts_song_id, do: NameSync.repropose(track)
  end

  defp ingest(%{path: path, title: title, url: url}, playlist_url) do
    parsed = TitleParser.parse(title)
    file = FileInfo.read(path)

    yt = %{"youtube_title" => title, "youtube_url" => url}
    yt = if playlist_url, do: Map.put(yt, "youtube_playlist_url", playlist_url), else: yt

    file
    |> Map.merge(%{
      rel_path: Path.relative_to(path, Library.library_root()),
      source_playlist: "youtube",
      status: :present,
      last_scanned_at: DateTime.truncate(DateTime.utc_now(), :second),
      tag_artist: parsed.artist,
      tag_title: parsed.title,
      raw_tags: Map.merge(file[:raw_tags] || %{}, yt)
    })
    |> Tracks.upsert_by_path()
  end
end
