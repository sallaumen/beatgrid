defmodule Beatgrid.Dashboard do
  @moduledoc """
  Read model and command surface for the dashboard.

  The dashboard LiveView should render and translate UI events; this module owns
  the operational knowledge behind the panel: progress snapshots, job enqueueing,
  recommendation updates, and the small notes shown after each command.
  """

  alias Beatgrid.{Analysis, Integrations, Loudness, Markers, Operations, Repertoire, YouTube}
  alias Beatgrid.Library.GenreFolders
  alias Beatgrid.Workers.{EnrichWorker, ExampleSetWorker, RecommendWorker}

  @doc "Subscribes the caller to every topic that can change the dashboard snapshot."
  @spec subscribe() :: :ok
  def subscribe do
    Analysis.subscribe()
    Loudness.subscribe()
    YouTube.subscribe()
    YouTube.subscribe_enrich()
    Repertoire.subscribe()
    :ok
  end

  @doc "Returns the complete read model used by the dashboard LiveView."
  @spec snapshot(String.t() | nil) :: map()
  def snapshot(selected_folder \\ nil) do
    folders = GenreFolders.list()
    gaps_folder = selected_folder || folders |> List.first() |> then(&(&1 && &1.key))

    %{
      page_title: "Painel",
      overview: Repertoire.overview(),
      genres: Repertoire.genre_distribution() |> Enum.sort_by(fn {_key, count} -> -count end),
      artists: Repertoire.top_artists(10),
      bpm: Repertoire.bpm_histogram(5) |> Enum.sort_by(fn {bucket, _count} -> bucket end),
      decades:
        Repertoire.decade_distribution() |> Enum.sort_by(fn {decade, _count} -> decade end),
      analysis: Analysis.progress(),
      analysis_note: nil,
      loudness: Loudness.progress(),
      gain_pending: Loudness.gain_pending_count(),
      gain_undo_batch: Loudness.latest_gain_batch(),
      loudness_note: nil,
      markers_unmapped: Markers.unmapped_count(),
      markers_note: nil,
      youtube_pending: YouTube.pending_count(),
      youtube_note: nil,
      enrich: nil,
      rare_pending: YouTube.rare_unfiled_count(),
      enrich_rare: nil,
      folders: folders,
      recommending?: false
    }
    |> Map.merge(gaps(gaps_folder))
  end

  @doc "Returns the selected folder's recommendation gaps plus per-folder counts."
  @spec gaps(String.t() | nil) :: map()
  def gaps(folder) do
    gaps = Repertoire.list_recommendations(source: :gaps, statuses: [:new, :imported])

    %{
      gaps_folder: folder,
      gap_counts: Enum.frequencies_by(gaps, & &1.genre_folder),
      recs: Enum.filter(gaps, &(&1.genre_folder == folder))
    }
  end

  @doc "Runs a dashboard command and returns either assign patches or a flash tuple."
  @spec run(term(), keyword()) :: {:ok, map()} | {:flash, atom(), String.t()}
  def run(command, opts \\ [])

  def run(:analyze_library, _opts) do
    {:ok, count} = Analysis.enqueue_pending()

    note =
      if count > 0,
        do: "#{count} faixa(s) enfileirada(s) — analisando em segundo plano…",
        else: "Tudo já analisado. ✔"

    {:ok, %{analysis: Analysis.progress(), analysis_note: note}}
  end

  def run(:map_markers, _opts) do
    {:ok, count} = Markers.enqueue_unmapped()

    note =
      if count == 0,
        do: "Tudo já mapeado — nenhuma faixa sem marcadores.",
        else: "Mapeando marcadores de #{count} faixa(s) em background — acompanhe em Jobs."

    {:ok, %{markers_unmapped: Markers.unmapped_count(), markers_note: note}}
  end

  def run(:build_example_set, _opts) do
    Oban.insert(ExampleSetWorker.new(%{}))

    {:flash, :info,
     "Montando set de exemplo (roots): detectando marcadores + conectando… abra REC SET em ~1 min."}
  end

  def run(:analyze_loudness, _opts) do
    {:ok, count} = Loudness.enqueue_pending()

    note =
      if count > 0,
        do: "#{count} faixa(s) na fila — medindo loudness em segundo plano…",
        else: "Loudness de tudo já medido. ✔"

    {:ok, %{loudness: Loudness.progress(), loudness_note: note}}
  end

  def run(:apply_gain, _opts) do
    {:ok, count, batch_id} = Loudness.enqueue_apply_pending()

    note =
      if count > 0,
        do: "#{count} track(s) queued for gain application.",
        else: "No tracks need gain application."

    {:ok,
     %{
       gain_pending: Loudness.gain_pending_count(),
       gain_undo_batch: if(count > 0, do: batch_id, else: Loudness.latest_gain_batch()),
       loudness_note: note
     }}
  end

  def run({:restore_gain_backup, nil}, _opts),
    do: {:ok, %{loudness_note: "No gain backup is available to restore."}}

  def run({:restore_gain_backup, batch_id}, _opts) do
    {:ok, %{undone: undone, failed: failed}} = Operations.undo_batch(batch_id)

    note =
      if failed == 0,
        do: "#{undone} gain backup(s) restored.",
        else: "#{undone} gain backup(s) restored; #{failed} restore(s) failed."

    {:ok,
     %{
       loudness: Loudness.progress(),
       gain_pending: Loudness.gain_pending_count(),
       gain_undo_batch: Loudness.latest_gain_batch(),
       loudness_note: note
     }}
  end

  def run({:download_youtube, urls}, _opts) do
    {:ok, count} = YouTube.enqueue(urls)

    note =
      if count > 0,
        do: "#{count} na fila — baixando em segundo plano. Acompanhe em Jobs.",
        else: "Cole ao menos uma URL do YouTube."

    {:ok, %{youtube_note: note}}
  end

  def run(:enrich_youtube, _opts) do
    if Integrations.configured?(:soundcharts) do
      enqueue_enrich("pending")
    else
      {:flash, :error, "Configure SOUNDCHARTS_APP_ID + SOUNDCHARTS_API_KEY no .env."}
    end
  end

  def run(:enrich_rare, _opts), do: enqueue_enrich("rare")

  def run({:fetch_gaps, folder}, _opts) do
    Oban.insert(
      RecommendWorker.new(%{
        "scope" => "folder",
        "folder" => folder,
        "batch_id" => Uniq.UUID.uuid7()
      })
    )

    {:ok, %{recommending?: true}}
  end

  def run({:download_recommendation, id}, opts) do
    folder = Keyword.fetch!(opts, :folder)
    current_note = Keyword.get(opts, :current_note)

    note =
      case Repertoire.get_recommendation(id) do
        nil ->
          current_note

        rec ->
          YouTube.enqueue("ytsearch1:" <> (rec.youtube_query || ""))
          Repertoire.set_recommendation_status(rec, :imported)
          "#{rec.artist} — #{rec.song}: na fila — veja em Jobs."
      end

    {:ok, Map.put(gaps(folder), :youtube_note, note)}
  end

  def run({:dismiss_recommendation, id}, opts) do
    folder = Keyword.fetch!(opts, :folder)

    case Repertoire.get_recommendation(id) do
      nil -> :ok
      rec -> Repertoire.set_recommendation_status(rec, :dismissed)
    end

    {:ok, gaps(folder)}
  end

  @doc "Returns assign patches for PubSub progress events consumed by the dashboard."
  @spec refresh(term()) :: {:ok, map()} | :ignore
  def refresh(:analysis_tick), do: {:ok, %{analysis: Analysis.progress()}}

  def refresh(:loudness_tick) do
    {:ok,
     %{
       loudness: Loudness.progress(),
       gain_pending: Loudness.gain_pending_count(),
       gain_undo_batch: Loudness.latest_gain_batch()
     }}
  end

  def refresh(:youtube_tick), do: {:ok, %{youtube_pending: YouTube.pending_count()}}

  def refresh({:enrich_progress, %{scope: "rare", status: :done} = payload}) do
    {:ok,
     %{
       enrich_rare: payload,
       rare_pending: YouTube.rare_unfiled_count(),
       youtube_pending: YouTube.pending_count()
     }}
  end

  def refresh({:enrich_progress, %{scope: "rare"} = payload}),
    do: {:ok, %{enrich_rare: payload}}

  def refresh({:enrich_progress, %{scope: "pending", status: :done} = payload}) do
    {:ok,
     %{
       enrich: payload,
       youtube_note: enrich_summary(payload),
       youtube_pending: YouTube.pending_count()
     }}
  end

  def refresh({:enrich_progress, %{scope: "pending"} = payload}),
    do: {:ok, %{enrich: payload}}

  def refresh({:enrich_progress, _payload}), do: :ignore

  @doc "Text shown after a pending enrichment batch finishes."
  @spec enrich_summary(map()) :: String.t()
  def enrich_summary(%{total: 0}), do: "Nada pendente para enriquecer."

  def enrich_summary(%{done: 0, budget_exhausted: true}),
    do: "Cota do Soundcharts esgotada em todas as contas."

  def enrich_summary(%{done: 0}),
    do: "Nada enriquecido — verifique a conta do Soundcharts (veja os logs)."

  def enrich_summary(%{done: count, resolved: resolved} = payload) do
    base = "#{count} enriquecida(s) (#{resolved} com match)"
    if payload[:budget_exhausted], do: base <> " — cota esgotada.", else: base <> "."
  end

  defp enqueue_enrich(scope) do
    batch_id = Uniq.UUID.uuid7()

    case Oban.insert(EnrichWorker.new(%{"scope" => scope, "batch_id" => batch_id})) do
      {:ok, %Oban.Job{conflict?: true}} ->
        {:ok, %{youtube_note: enrich_conflict_note(scope)}}

      {:ok, _job} ->
        {:ok, enrich_queued_patch(scope)}

      {:error, _reason} ->
        {:ok, %{youtube_note: enrich_error_note(scope)}}
    end
  end

  defp enrich_queued_patch("rare"), do: %{enrich_rare: %{status: :queued}, youtube_note: nil}
  defp enrich_queued_patch(_pending), do: %{enrich: %{status: :queued}, youtube_note: nil}

  defp enrich_conflict_note("rare"),
    do: "Já existe um enriquecimento de raras em andamento — veja em Jobs."

  defp enrich_conflict_note(_pending),
    do: "Já existe um enriquecimento em andamento — veja em Jobs."

  defp enrich_error_note("rare"), do: "Não foi possível iniciar o enriquecimento das raras."
  defp enrich_error_note(_pending), do: "Não foi possível iniciar o enriquecimento."
end
