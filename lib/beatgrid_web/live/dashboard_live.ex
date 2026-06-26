defmodule BeatgridWeb.DashboardLive do
  @moduledoc "Painel — library KPIs, distribution charts, and AI repertoire gaps."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.{AI, Analysis, Repertoire, YouTube}
  alias Beatgrid.Library.GenreFolders

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Analysis.subscribe()
      YouTube.subscribe()
    end

    folders = GenreFolders.list()

    {:ok,
     assign(socket,
       page_title: "Painel",
       overview: Repertoire.overview(),
       genres: Repertoire.genre_distribution() |> Enum.sort_by(fn {_k, v} -> -v end),
       artists: Repertoire.top_artists(10),
       bpm: Repertoire.bpm_histogram(5) |> Enum.sort_by(fn {b, _} -> b end),
       decades: Repertoire.decade_distribution() |> Enum.sort_by(fn {d, _} -> d end),
       analysis: Analysis.progress(),
       analysis_note: nil,
       youtube_pending: YouTube.pending_count(),
       youtube_note: nil,
       folders: folders,
       gaps_folder: folders |> List.first() |> then(&(&1 && &1.key)),
       gaps: nil,
       gaps_loading: false,
       gaps_error: nil
     )}
  end

  @impl true
  def handle_event("analyze_library", _params, socket) do
    {:ok, n} = Analysis.enqueue_pending()

    note =
      if n > 0,
        do: "#{n} faixa(s) enfileirada(s) — analisando em segundo plano…",
        else: "Tudo já analisado. ✔"

    {:noreply, assign(socket, analysis: Analysis.progress(), analysis_note: note)}
  end

  def handle_event("download_youtube", %{"urls" => urls}, socket) do
    {:ok, n} = YouTube.enqueue(urls)

    note =
      if n > 0,
        do: "#{n} download(s) enfileirado(s) — baixando em segundo plano…",
        else: "Cole ao menos uma URL do YouTube."

    {:noreply, assign(socket, youtube_note: note)}
  end

  def handle_event("select_folder", %{"folder" => key}, socket) do
    {:noreply, assign(socket, gaps_folder: key, gaps: nil, gaps_error: nil)}
  end

  def handle_event("fetch_gaps", _params, socket) do
    folder = socket.assigns.gaps_folder

    {:noreply,
     socket
     |> assign(gaps_loading: true, gaps: nil, gaps_error: nil)
     |> start_async(:gaps, fn -> AI.suggest_gaps(folder, count: 8) end)}
  end

  @impl true
  def handle_async(:gaps, {:ok, {:ok, gaps}}, socket) do
    {:noreply, assign(socket, gaps_loading: false, gaps: gaps)}
  end

  def handle_async(:gaps, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, gaps_loading: false, gaps_error: inspect(reason))}
  end

  def handle_async(:gaps, {:exit, reason}, socket) do
    {:noreply, assign(socket, gaps_loading: false, gaps_error: inspect(reason))}
  end

  @impl true
  def handle_info({:analysis_tick}, socket) do
    {:noreply, assign(socket, analysis: Analysis.progress())}
  end

  def handle_info({:youtube_tick}, socket) do
    {:noreply, assign(socket, youtube_pending: YouTube.pending_count())}
  end

  # --- helpers ---

  defp pct(_value, 0), do: 0
  defp pct(value, max), do: max(round(value / max * 100), 2)

  defp max_count([]), do: 0
  defp max_count(list), do: list |> Enum.map(fn {_k, v} -> v end) |> Enum.max()

  defp decade_label(d), do: "#{d}s"

  defp conf(by_confidence, level), do: Map.get(by_confidence, level, 0)

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:painel}>
      <div class="h-screen overflow-y-auto">
        <header class="border-b border-white/6 bg-rail px-5 py-3">
          <h2 class="text-[22px] font-semibold">Painel</h2>
          <p class="text-body-sm text-ink-muted">{@overview.total} faixas na biblioteca</p>
        </header>

        <div class="mx-auto max-w-6xl space-y-5 px-6 py-5">
          <section class="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
            <.kpi_card label="Total" value={@overview.total} color="#8b7bf0" />
            <.kpi_card
              label="Resolvidas"
              value={@overview.resolved}
              sub="com metadados"
              color="#5ad1a0"
            />
            <.kpi_card label="Sem match" value={@overview.unresolved} color="#ffb020" />
            <.kpi_card
              label="Truncadas"
              value={@overview.truncated}
              alert={@overview.truncated > 0}
              color={if @overview.truncated > 0, do: "#ff5d6c", else: "#eef0f5"}
            />
            <.kpi_card
              label="Conf. alta"
              value={conf(@overview.by_confidence, :high)}
              color="#5ad1a0"
            />
            <.kpi_card
              label="Conf. baixa"
              value={conf(@overview.by_confidence, :low)}
              color="#ff5d6c"
            />
          </section>

          <.panel title="Operações">
            <div class="flex items-center justify-between gap-4">
              <div class="min-w-0 flex-1">
                <div class="flex items-center justify-between text-body-sm">
                  <span class="text-ink-secondary">Análise de áudio local (BPM + tom)</span>
                  <span class="font-mono text-ink-muted">
                    {@analysis.analyzed}/{@analysis.total} analisadas
                  </span>
                </div>
                <div class="mt-1.5 h-[7px] rounded-full bg-white/5">
                  <div
                    class="h-full rounded-full bg-green transition-all"
                    style={"width:#{pct(@analysis.analyzed, @analysis.total)}%"}
                  >
                  </div>
                </div>
                <p :if={@analysis_note} class="mt-1.5 text-caption text-ink-muted">
                  {@analysis_note}
                </p>
              </div>
              <button
                phx-click="analyze_library"
                disabled={@analysis.analyzed >= @analysis.total}
                class="shrink-0 rounded-md bg-primary px-3.5 py-1.5 text-body-sm font-semibold text-white disabled:opacity-40"
              >
                Analisar faltantes ({max(@analysis.total - @analysis.analyzed, 0)})
              </button>
            </div>
          </.panel>

          <.panel title="Importar do YouTube">
            <form id="youtube-form" phx-submit="download_youtube" class="space-y-2">
              <textarea
                name="urls"
                rows="3"
                placeholder="Cole URLs do YouTube (uma por linha) ou uma URL de playlist…"
                class="w-full rounded-md border border-white/8 bg-input px-3 py-2 text-body-sm focus:border-primary/50 focus:outline-none"
              ></textarea>
              <div class="flex items-center justify-between gap-3">
                <span class="text-caption text-ink-muted">
                  Pendentes de enriquecimento: {@youtube_pending}
                </span>
                <button class="rounded-md bg-primary px-3.5 py-1.5 text-body-sm font-semibold text-white">
                  Baixar
                </button>
              </div>
              <p :if={@youtube_note} class="text-caption text-ink-muted">{@youtube_note}</p>
            </form>
            <p class="mt-1 text-caption text-ink-faint">
              Baixar é offline (não gasta cota). Depois enriqueça os metadados e revise na Central de Revisão.
            </p>
          </.panel>

          <div class="grid grid-cols-1 gap-5 lg:grid-cols-2">
            <.panel title="Distribuição por gênero">
              <div :if={@genres != []} class="space-y-2">
                <.bar_row
                  :for={{key, n} <- @genres}
                  label={folder_label(key)}
                  value={n}
                  max={max_count(@genres)}
                  color={folder_color(key)}
                />
              </div>
              <.empty :if={@genres == []} />
            </.panel>

            <.panel title="Top artistas">
              <div :if={@artists != []} class="space-y-2">
                <.bar_row
                  :for={{artist, n} <- @artists}
                  label={artist}
                  value={n}
                  max={max_count(@artists)}
                  color="#8b7bf0"
                />
              </div>
              <.empty :if={@artists == []} />
            </.panel>

            <.panel title="Faixas de BPM">
              <div :if={@bpm != []}>
                <div class="flex items-end gap-1" style="height:120px">
                  <div
                    :for={{_b, n} <- @bpm}
                    class="flex-1 rounded-t-[4px]"
                    style={"height:#{pct(n, max_count(@bpm))}%;min-height:6px;background:linear-gradient(180deg,#8b7bf0,#6c5ce7)"}
                  >
                  </div>
                </div>
                <div class="mt-1 flex gap-1">
                  <span :for={{b, _n} <- @bpm} class="flex-1 text-center text-[9px] text-ink-faint">
                    {b}
                  </span>
                </div>
              </div>
              <.empty :if={@bpm == []} />
            </.panel>

            <.panel title="Décadas">
              <div :if={@decades != []} class="space-y-2">
                <.bar_row
                  :for={{d, n} <- @decades}
                  label={decade_label(d)}
                  value={n}
                  max={max_count(@decades)}
                  color="#2d9cff"
                />
              </div>
              <.empty :if={@decades == []} />
            </.panel>
          </div>

          <.panel title="Lacunas no repertório (IA)">
            <form id="gaps-form" phx-change="select_folder" class="flex items-center gap-2">
              <select
                name="folder"
                class="rounded-md border border-white/8 bg-input px-2.5 py-1.5 text-body-sm focus:border-primary/50 focus:outline-none"
              >
                <option :for={f <- @folders} value={f.key} selected={f.key == @gaps_folder}>
                  {f.display_name}
                </option>
              </select>
              <button
                type="button"
                phx-click="fetch_gaps"
                disabled={@gaps_loading or is_nil(@gaps_folder)}
                class="rounded-md bg-primary px-3.5 py-1.5 text-body-sm font-semibold text-white disabled:opacity-40"
              >
                {if @gaps_loading, do: "Consultando a IA…", else: "Buscar lacunas"}
              </button>
            </form>

            <div
              :if={@gaps_loading}
              class="mt-3 flex items-center gap-2 rounded-lg border border-primary/30 bg-primary/8 px-3 py-2 text-body-sm text-ink"
            >
              <span class="size-2.5 animate-pulse rounded-full bg-primary"></span>
              Consultando a IA… isso pode levar ~20–30s.
            </div>

            <div
              :if={@gaps_error}
              class="mt-3 rounded-lg border border-coral/25 bg-coral/8 px-3 py-2 text-body-sm text-ink"
            >
              ⚠ Falha ao consultar a IA: {@gaps_error}
            </div>

            <div :if={@gaps && @gaps != []} class="mt-3 space-y-1.5">
              <div
                :for={g <- @gaps}
                class="rounded-lg border border-white/6 bg-base px-3 py-2"
              >
                <p class="text-body font-medium">
                  {g.artist} <span class="text-ink-faint">—</span> {g.song}
                </p>
                <p class="mt-0.5 text-caption text-ink-muted">{g.reason}</p>
              </div>
            </div>

            <p :if={@gaps == []} class="mt-3 text-body-sm text-ink-faint">
              Nenhuma lacuna sugerida para esta pasta.
            </p>
          </.panel>
        </div>
      </div>
    </.app_shell>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section class="rounded-xl border border-white/6 bg-surface p-4">
      <p class="mb-3 text-[10px] font-semibold uppercase tracking-wider text-ink-faint">{@title}</p>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :max, :integer, required: true
  attr :color, :string, default: "#8b7bf0"

  defp bar_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2.5">
      <span class="w-28 shrink-0 truncate text-[12px] text-ink-secondary">{@label}</span>
      <div class="h-[7px] flex-1 rounded-full bg-white/5">
        <div class="h-full rounded-full" style={"width:#{pct(@value, @max)}%;background:#{@color}"}>
        </div>
      </div>
      <span class="w-8 shrink-0 text-right font-mono text-[11px] text-ink-muted">{@value}</span>
    </div>
    """
  end

  defp empty(assigns) do
    ~H"""
    <p class="text-body-sm text-ink-faint">Sem dados ainda.</p>
    """
  end
end
