defmodule Beatgrid.YouTube do
  @moduledoc """
  YouTube ingestion. Downloads audio (one video or a whole playlist) into `_Inbox`
  and creates a `Track` per file with a best-effort artist/title from the video
  title — **offline**, spending no metadata-API quota. Enrichment (resolving against
  Soundcharts, proposing renames/classifications) is a separate, explicit step.

  Downloads run as background `DownloadWorker` jobs; the screen follows progress via
  the `"youtube"` PubSub topic.
  """
  alias Beatgrid.Library
  alias Beatgrid.Library.{FileInfo, Tracks}
  alias Beatgrid.Workers.DownloadWorker
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
    Enum.each(urls, fn url -> %{url: url} |> DownloadWorker.new() |> Oban.insert() end)
    {:ok, length(urls)}
  end

  @doc """
  Downloads a URL (video or playlist) and ingests each resulting file into `_Inbox`.
  Returns `{:ok, ingested_count}` or the downloader's `{:error, reason}`.
  """
  @spec download_and_ingest(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def download_and_ingest(url) do
    dest = Path.join(Library.library_root(), "_Inbox")

    with {:ok, items} <- @adapter.download(url, dest) do
      ingested = items |> Enum.map(&ingest/1) |> Enum.count(&match?({:ok, _}, &1))
      {:ok, ingested}
    end
  end

  defp ingest(%{path: path, title: title, url: url}) do
    parsed = TitleParser.parse(title)
    file = FileInfo.read(path)

    file
    |> Map.merge(%{
      rel_path: Path.relative_to(path, Library.library_root()),
      source_playlist: "youtube",
      status: :present,
      last_scanned_at: DateTime.truncate(DateTime.utc_now(), :second),
      tag_artist: parsed.artist,
      tag_title: parsed.title,
      raw_tags:
        Map.merge(file[:raw_tags] || %{}, %{"youtube_title" => title, "youtube_url" => url})
    })
    |> Tracks.upsert_by_path()
  end
end
