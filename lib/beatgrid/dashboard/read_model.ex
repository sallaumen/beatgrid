defmodule Beatgrid.Dashboard.ReadModel do
  @moduledoc """
  The dashboard's read side: the full snapshot, the gaps breakdown, and the
  assign patches derived from PubSub progress events. No command lives here —
  enqueueing and mutations belong to `Beatgrid.Dashboard.Commands`.
  """

  alias Beatgrid.{Analysis, Loudness, Markers, Repertoire, YouTube}
  alias Beatgrid.Library.GenreFolders

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
end
