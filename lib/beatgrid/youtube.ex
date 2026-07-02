defmodule Beatgrid.YouTube do
  @moduledoc """
  YouTube ingestion. `ExpandWorker` lists a submitted URL's videos and fans out
  one `DownloadWorker` per video; each worker downloads a single video into
  `_Inbox` and creates a `Track` with a best-effort artist/title — **offline**,
  spending no metadata-API quota. Enrichment (resolving against Soundcharts,
  proposing renames/classifications) is a separate, explicit step.

  Downloads run as background `DownloadWorker` jobs; the screen follows progress via
  the `"youtube"` PubSub topic.
  """
  require Logger

  alias Beatgrid.{Gold, Library, Review, Soundcharts}
  alias Beatgrid.Library.{FileInfo, NameSync, Tracks}
  alias Beatgrid.Library.MetadataAI
  alias Beatgrid.Organization.ClassificationAI
  alias Beatgrid.Workers.{AnalyzeWorker, DownloadWorker, ExpandWorker}
  alias Beatgrid.YouTube.TitleParser

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.YouTube.Downloader, :adapter],
             Beatgrid.YouTube.YtDlp
           )

  @topic "youtube"
  @enrich_topic "enrich"

  @doc "Subscribe to download-progress ticks."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, @topic)

  @doc "Broadcast a `{:youtube_tick}` after a download finishes."
  @spec broadcast_tick() :: :ok
  def broadcast_tick, do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, @topic, {:youtube_tick})

  @doc "Subscribe to enrich-progress events (`{:enrich_progress, payload}`)."
  @spec subscribe_enrich() :: :ok | {:error, term()}
  def subscribe_enrich, do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, @enrich_topic)

  @doc "Broadcast an enrich-progress event (separate from the download topic)."
  @spec broadcast_enrich(map()) :: :ok
  def broadcast_enrich(payload),
    do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, @enrich_topic, {:enrich_progress, payload})

  @doc "Count of tracks downloaded but not yet enriched (present, unresolved, unfiled, never attempted with Soundcharts)."
  @spec pending_count() :: non_neg_integer()
  def pending_count,
    do: Tracks.count(status: :present, resolved: false, genre_folder: nil, sc_attempted: false)

  @doc "Enqueues one `ExpandWorker` per non-blank URL (lines or a list), which fans each out to one `DownloadWorker` per video. Returns `{:ok, count}`."
  @spec enqueue(String.t() | [String.t()]) :: {:ok, non_neg_integer()}
  def enqueue(urls) when is_binary(urls), do: urls |> String.split("\n") |> enqueue()

  def enqueue(urls) when is_list(urls) do
    urls = urls |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    Enum.each(urls, fn url -> {:ok, _job} = ExpandWorker.enqueue(url) end)
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
      enqueue_entries(url, entries)
    end
  end

  defp enqueue_entries(_url, []), do: {:error, :no_entries}

  defp enqueue_entries(url, entries) do
    playlist_url = if length(entries) > 1, do: url, else: nil

    Enum.each(entries, fn e ->
      {:ok, _job} =
        DownloadWorker.enqueue(e.url, video_id: e.id, title: e.title, playlist_url: playlist_url)
    end)

    broadcast_tick()
    {:ok, length(entries)}
  end

  @doc """
  Downloads one video URL and ingests each resulting file into `_Inbox`.
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
  Resolves ONE track against Soundcharts (spends quota), reproposes a rename if
  matched, and re-evaluates its pending rename suggestions. Returns
  `:resolved | :no_match | :budget_exhausted`. This is the quota-spending,
  per-track step shared by the on-demand and batch enrich flows (it does NOT
  reclassify — callers batch that to keep AI calls together).
  """
  # Note: the AI re-evaluation of the resulting rename suggestion is NOT done here —
  # it's batched by the caller (the worker does `Review.reevaluate_tracks/1` once at
  # the end; `enrich_track/1` does it for its single track). Per-track AI calls in
  # the loop made large batches crawl.
  @spec resolve_track_enrich(binary()) :: :resolved | :no_match | :budget_exhausted
  def resolve_track_enrich(id) do
    case id |> Tracks.get() |> Soundcharts.resolve_track() do
      {:error, :budget_exhausted} ->
        :budget_exhausted

      result ->
        # Surface real failures (HTTP/timeout) instead of silently calling them
        # "no match" — :no_match is a legitimate outcome, other errors are not.
        case result do
          {:error, :no_credentials} ->
            Logger.error(
              "enrich: Soundcharts SEM CREDENCIAIS — carregue o .env " <>
                "(SOUNDCHARTS_APP_ID/SOUNDCHARTS_API_KEY) e reinicie o servidor"
            )

          {:error, reason} when reason != :no_match ->
            Logger.warning("enrich: Soundcharts falhou na faixa #{id}: #{inspect(reason)}")

          _ ->
            :ok
        end

        repropose_if_matched(id)
        Gold.apply_resolve_result(Tracks.get(id), result)

        if match?({:error, :no_match}, result) do
          Tracks.update(Tracks.get(id), %{
            sc_attempted_at: DateTime.truncate(DateTime.utc_now(), :second)
          })
        end

        if match?({:ok, _}, result), do: :resolved, else: :no_match
    end
  end

  @doc """
  Enriches ONE track on demand: resolves it against Soundcharts (spends quota),
  re-proposes a rename if it matched, then runs the offline fallback (`enrich_fallback/1`:
  local audio analysis when BPM is missing + AI genre classification, auto-filing the
  high-confidence ones). Same fallback the batch/rare flows use. Returns
  `{:ok, %{resolved: boolean}}` on success or `{:error, :budget_exhausted}` when the
  quota floor is reached.
  """
  @spec enrich_track(binary()) ::
          {:ok, %{resolved: boolean()}} | {:error, :budget_exhausted}
  def enrich_track(id) do
    case resolve_track_enrich(id) do
      :budget_exhausted ->
        {:error, :budget_exhausted}

      outcome ->
        Review.reevaluate_track(id)
        enrich_fallback([id])
        {:ok, %{resolved: outcome == :resolved}}
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

    Enum.each(ids, fn id ->
      track = Tracks.get(id)
      result = Soundcharts.resolve_track(track)
      Gold.apply_resolve_result(track, result)
    end)

    Enum.each(ids, &repropose_if_matched/1)
    Review.reevaluate_tracks(ids)
    ClassificationAI.reclassify(tracks: Enum.map(ids, &Tracks.get/1))

    resolved = Enum.count(ids, &(Tracks.get(&1).soundcharts_song_id != nil))
    {:ok, %{enriched: length(ids), resolved: resolved}}
  end

  @doc "Ids of pending (downloaded-but-unfiled) tracks: present, unresolved, unfiled, never attempted with Soundcharts."
  @spec pending_ids() :: [binary()]
  def pending_ids do
    [status: :present, resolved: false, genre_folder: nil, sc_attempted: false]
    |> Tracks.list_by()
    |> Enum.map(& &1.id)
  end

  @doc "Faixas que o Soundcharts já tentou e não achou, ainda não arquivadas (raras/Ouro)."
  @spec rare_unfiled_count() :: non_neg_integer()
  def rare_unfiled_count,
    do: Tracks.count(status: :present, resolved: false, genre_folder: nil, sc_attempted: true)

  @spec rare_unfiled_ids() :: [binary()]
  def rare_unfiled_ids do
    [status: :present, resolved: false, genre_folder: nil, sc_attempted: true]
    |> Tracks.list_by()
    |> Enum.map(& &1.id)
  end

  @doc """
  Fallback de enriquecimento (sem Soundcharts): enfileira análise local pras faixas
  sem `bpm_detected` (BPM/tom reais) e roda a classificação de gênero por IA, que
  auto-arquiva as de alta confiança. Idempotente (AnalyzeWorker é unique por faixa;
  reclassify pula quem já tem pasta ou proposta pendente).
  """
  @spec enrich_fallback([binary()]) :: :ok
  def enrich_fallback(ids) do
    tracks = Enum.map(ids, &Tracks.get/1) |> Enum.reject(&is_nil/1)

    Enum.each(tracks, fn t ->
      if is_nil(t.bpm_detected), do: AnalyzeWorker.enqueue(t.id)
    end)

    if tracks != [], do: ClassificationAI.reclassify(tracks: tracks)
    :ok
  end

  @doc """
  Ask the AI to extract artist/title for tracks the heuristic couldn't split (batched,
  no quota). `on_progress.(done, total)` fires per batch so the caller can show that
  the (otherwise silent) refine phase is moving.
  """
  @spec refine_titles([binary()], (non_neg_integer(), non_neg_integer() -> any())) :: :ok
  def refine_titles(ids, on_progress \\ fn _done, _total -> :ok end) do
    ambiguous = ids |> Enum.map(&Tracks.get/1) |> Enum.filter(&ambiguous?/1)
    Logger.info("YouTube.refine_titles: #{length(ambiguous)} ambíguos de #{length(ids)} faixas")

    with [_ | _] <- ambiguous,
         {:ok, parsed} <-
           MetadataAI.parse_titles(Enum.map(ambiguous, &raw_title/1), on_progress) do
      refined =
        ambiguous
        |> Enum.zip(parsed)
        # Skip placeholders (a failed AI batch yields nil fields) so we never wipe a
        # title with nothing.
        |> Enum.count(fn {t, p} ->
          p.artist &&
            match?({:ok, _}, Tracks.update(t, %{tag_artist: p.artist, tag_title: p.title}))
        end)

      Logger.info("YouTube.refine_titles: #{refined} título(s) refinado(s) pela IA")
    end

    :ok
  end

  defp ambiguous?(track), do: is_nil(track.tag_artist) and is_binary(raw_title(track))
  defp raw_title(track), do: (track.raw_tags || %{})["youtube_title"] || track.tag_title

  defp repropose_if_matched(id) do
    track = Tracks.get_with_song(id)
    if track && track.soundcharts_song_id, do: NameSync.repropose(track)
  end

  defp ingest(%{path: path, title: title, url: url} = item, playlist_url) do
    parsed = TitleParser.parse(title)
    file = FileInfo.read(path)

    yt = %{"youtube_title" => title, "youtube_url" => url}
    yt = if playlist_url, do: Map.put(yt, "youtube_playlist_url", playlist_url), else: yt

    attrs =
      Map.merge(file, %{
        rel_path: Path.relative_to(path, Library.library_root()),
        source_playlist: "youtube",
        status: :present,
        last_scanned_at: DateTime.truncate(DateTime.utc_now(), :second),
        tag_artist: parsed.artist,
        tag_title: parsed.title,
        youtube_views: Map.get(item, :views),
        youtube_published_at: parse_upload_date(Map.get(item, :upload_date)),
        raw_tags: Map.merge(file[:raw_tags] || %{}, yt)
      })

    case Tracks.upsert_by_path(attrs) do
      {:ok, track} -> Gold.maybe_mark_candidate(track)
      error -> error
    end
  end

  defp parse_upload_date(<<y::binary-4, m::binary-2, d::binary-2>>) do
    case Date.from_iso8601("#{y}-#{m}-#{d}") do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_upload_date(_), do: nil
end
