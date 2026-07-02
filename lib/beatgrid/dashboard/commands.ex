defmodule Beatgrid.Dashboard.Commands do
  @moduledoc """
  The dashboard's command side: each `run/2` clause dispatches one panel action
  (enqueue a batch, restore a backup, update a recommendation) and returns either
  assign patches or a flash tuple. Reads that feed the panel live in
  `Beatgrid.Dashboard.ReadModel`.
  """

  alias Beatgrid.{Analysis, Integrations, Loudness, Markers, Operations, Repertoire, YouTube}
  alias Beatgrid.Dashboard.ReadModel
  alias Beatgrid.Workers.{EnrichWorker, ExampleSetWorker, RecommendWorker}

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
    {:ok, _job} = ExampleSetWorker.enqueue()

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
    {:ok, _job} = RecommendWorker.enqueue_for_folder(folder)

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

    {:ok, Map.put(ReadModel.gaps(folder), :youtube_note, note)}
  end

  def run({:dismiss_recommendation, id}, opts) do
    folder = Keyword.fetch!(opts, :folder)

    case Repertoire.get_recommendation(id) do
      nil -> :ok
      rec -> Repertoire.set_recommendation_status(rec, :dismissed)
    end

    {:ok, ReadModel.gaps(folder)}
  end

  defp enqueue_enrich(scope) do
    case EnrichWorker.enqueue(scope) do
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
