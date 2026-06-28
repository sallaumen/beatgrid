defmodule BeatgridWeb.DashboardLive do
  @moduledoc "Painel — library KPIs, distribution charts, and AI repertoire gaps."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.{Analysis, Loudness, Repertoire, YouTube}
  alias Beatgrid.Library.GenreFolders
  alias Beatgrid.Workers.{EnrichWorker, RecommendWorker}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Analysis.subscribe()
      Loudness.subscribe()
      YouTube.subscribe()
      YouTube.subscribe_enrich()
      Repertoire.subscribe()
    end

    folders = GenreFolders.list()
    gaps_folder = folders |> List.first() |> then(&(&1 && &1.key))

    {:ok,
     socket
     |> assign(
       page_title: "Painel",
       overview: Repertoire.overview(),
       genres: Repertoire.genre_distribution() |> Enum.sort_by(fn {_k, v} -> -v end),
       artists: Repertoire.top_artists(10),
       bpm: Repertoire.bpm_histogram(5) |> Enum.sort_by(fn {b, _} -> b end),
       decades: Repertoire.decade_distribution() |> Enum.sort_by(fn {d, _} -> d end),
       analysis: Analysis.progress(),
       analysis_note: nil,
       loudness: Loudness.progress(),
       loudness_note: nil,
       youtube_pending: YouTube.pending_count(),
       youtube_note: nil,
       enrich: nil,
       folders: folders,
       recommending?: false
     )
     |> assign_gaps(gaps_folder)}
  end

  # One query feeds both the per-folder gap counts (for the folder chips) and the
  # selected folder's recommendation list — grouping/filtering in Elixir avoids a
  # second round-trip. Re-run whenever the gaps change (selection, generate, import,
  # dismiss).
  defp assign_gaps(socket, folder) do
    gaps = Repertoire.list_recommendations(source: :gaps, statuses: [:new, :imported])

    assign(socket,
      gaps_folder: folder,
      gap_counts: Enum.frequencies_by(gaps, & &1.genre_folder),
      recs: Enum.filter(gaps, &(&1.genre_folder == folder))
    )
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

  def handle_event("analyze_loudness", _params, socket) do
    {:ok, n} = Loudness.enqueue_pending()

    note =
      if n > 0,
        do: "#{n} faixa(s) na fila — medindo loudness em segundo plano…",
        else: "Loudness de tudo já medido. ✔"

    {:noreply, assign(socket, loudness: Loudness.progress(), loudness_note: note)}
  end

  def handle_event("download_youtube", %{"urls" => urls}, socket) do
    {:ok, n} = YouTube.enqueue(urls)

    note =
      if n > 0,
        do: "#{n} na fila — baixando em segundo plano. Acompanhe em Jobs.",
        else: "Cole ao menos uma URL do YouTube."

    {:noreply, assign(socket, youtube_note: note)}
  end

  def handle_event("enrich_youtube", _params, socket) do
    bid = Uniq.UUID.uuid7()

    # The worker is `unique` per scope, so a click while one is already running is a
    # no-op (conflict) — surface that instead of faking a fresh "queued" progress.
    case Oban.insert(EnrichWorker.new(%{"scope" => "pending", "batch_id" => bid})) do
      {:ok, %Oban.Job{conflict?: true}} ->
        {:noreply,
         assign(socket, youtube_note: "Já existe um enriquecimento em andamento — veja em Jobs.")}

      {:ok, _job} ->
        {:noreply, assign(socket, enrich: %{status: :queued}, youtube_note: nil)}

      {:error, _reason} ->
        {:noreply, assign(socket, youtube_note: "Não foi possível iniciar o enriquecimento.")}
    end
  end

  def handle_event("select_folder", %{"folder" => key}, socket) do
    {:noreply, assign_gaps(socket, key)}
  end

  def handle_event("fetch_gaps", _params, socket) do
    folder = socket.assigns.gaps_folder

    Oban.insert(
      RecommendWorker.new(%{
        "scope" => "folder",
        "folder" => folder,
        "batch_id" => Uniq.UUID.uuid7()
      })
    )

    {:noreply, assign(socket, recommending?: true)}
  end

  def handle_event("download_rec", %{"id" => id}, socket) do
    note =
      case Repertoire.get_recommendation(id) do
        nil ->
          socket.assigns.youtube_note

        rec ->
          YouTube.enqueue("ytsearch1:" <> (rec.youtube_query || ""))
          Repertoire.set_recommendation_status(rec, :imported)
          "#{rec.artist} — #{rec.song}: na fila — veja em Jobs."
      end

    {:noreply, socket |> assign_gaps(socket.assigns.gaps_folder) |> assign(youtube_note: note)}
  end

  def handle_event("dismiss_rec", %{"id" => id}, socket) do
    case Repertoire.get_recommendation(id) do
      nil -> :ok
      rec -> Repertoire.set_recommendation_status(rec, :dismissed)
    end

    {:noreply, assign_gaps(socket, socket.assigns.gaps_folder)}
  end

  @impl true
  def handle_info({:analysis_tick}, socket) do
    {:noreply, assign(socket, analysis: Analysis.progress())}
  end

  def handle_info({:loudness_tick}, socket) do
    {:noreply, assign(socket, loudness: Loudness.progress())}
  end

  def handle_info({:youtube_tick}, socket) do
    {:noreply, assign(socket, youtube_pending: YouTube.pending_count())}
  end

  # Batch enrich progress (only the "pending" scope concerns the dashboard).
  def handle_info({:enrich_progress, %{scope: "pending", status: :done} = p}, socket) do
    {:noreply,
     assign(socket,
       enrich: p,
       youtube_note: enrich_summary(p),
       youtube_pending: YouTube.pending_count()
     )}
  end

  def handle_info({:enrich_progress, %{scope: "pending"} = p}, socket) do
    {:noreply, assign(socket, enrich: p)}
  end

  def handle_info({:enrich_progress, _payload}, socket), do: {:noreply, socket}

  # Folder recommendation finished generating. Reload the persisted gaps and clear
  # the "Gerando…" state — but only for the folder currently on screen. Other
  # folders' ticks just clear the spinner.
  def handle_info({:recommend_progress, %{scope: "folder", key: key, status: status}}, socket)
      when status in [:done, :error] do
    if key == socket.assigns.gaps_folder do
      {:noreply, socket |> assign(recommending?: false) |> assign_gaps(key)}
    else
      {:noreply, assign(socket, recommending?: false)}
    end
  end

  def handle_info({:recommend_progress, _payload}, socket), do: {:noreply, socket}

  # Order matters: distinguish "0 because nothing was pending" from "0 because the
  # quota ran out / no credentials" — the latter must NOT read as "nada pendente".
  defp enrich_summary(%{total: 0}), do: "Nada pendente para enriquecer."

  defp enrich_summary(%{done: 0, budget_exhausted: true}),
    do: "Cota do Soundcharts esgotada — 0 enriquecida(s). Configure/carregue a 2ª conta no .env."

  defp enrich_summary(%{done: 0}),
    do: "Nada enriquecido — sem cota ou credenciais? Veja os logs do servidor."

  defp enrich_summary(%{done: n, resolved: r} = p) do
    base = "#{n} enriquecida(s) (#{r} com match)"
    if p[:budget_exhausted], do: base <> " — cota esgotada.", else: base <> "."
  end

  # --- helpers ---

  defp pct(_value, 0), do: 0
  defp pct(value, max), do: max(round(value / max * 100), 2)

  defp max_count([]), do: 0
  defp max_count(list), do: list |> Enum.map(fn {_k, v} -> v end) |> Enum.max()

  defp decade_label(d), do: "#{d}s"

  defp conf(by_confidence, level), do: Map.get(by_confidence, level, 0)

  # Enrich progress-bar helpers (mirrors ReviewLive's reeval bar).
  defp enrich_running?(%{status: status})
       when status in [:queued, :running, :refining, :finishing],
       do: true

  defp enrich_running?(_enrich), do: false

  defp enrich_label(%{status: :queued}), do: "Enriquecendo — na fila…"

  defp enrich_label(%{status: :refining, done: d, total: t}),
    do: "Refinando títulos com IA #{d}/#{t}…"

  defp enrich_label(%{status: :running, done: d, total: t}),
    do: "Resolvendo no Soundcharts #{d}/#{t}…"

  defp enrich_label(%{status: :finishing}), do: "Reavaliando e classificando com IA…"

  defp enrich_label(_enrich), do: "Enriquecendo…"

  # During :finishing the per-item bar is full; show 100 so it doesn't look stalled.
  defp enrich_pct(%{status: :finishing}), do: 100
  defp enrich_pct(%{done: d, total: t}) when is_integer(t) and t > 0, do: round(d / t * 100)
  defp enrich_pct(_enrich), do: 0

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:painel} socket={@socket}>
      <div class="h-[calc(100vh_-_5rem)] overflow-y-auto">
        <header class="border-b border-white/6 bg-rail px-5 py-3">
          <h2 class="text-[22px] font-semibold">Painel</h2>
          <p class="text-body-sm text-ink-muted">{@overview.total} faixas na biblioteca</p>
        </header>

        <div class="mx-auto max-w-[1600px] space-y-5 px-6 py-5">
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

            <div class="mt-4 flex items-center justify-between gap-4 border-t border-white/6 pt-4">
              <div class="min-w-0 flex-1">
                <div class="flex items-center justify-between text-body-sm">
                  <span class="text-ink-secondary">Loudness (LUFS)</span>
                  <span class="font-mono text-ink-muted">
                    {@loudness.measured}/{@loudness.total} medidas
                  </span>
                </div>
                <div class="mt-1.5 h-[7px] rounded-full bg-white/5">
                  <div
                    class="bg-amber h-full rounded-full transition-all"
                    style={"width:#{pct(@loudness.measured, @loudness.total)}%"}
                  >
                  </div>
                </div>
                <p :if={@loudness_note} class="mt-1.5 text-caption text-ink-muted">
                  {@loudness_note}
                </p>
              </div>
              <button
                phx-click="analyze_loudness"
                disabled={@loudness.measured >= @loudness.total}
                class="text-amber shrink-0 rounded-md bg-amber/20 px-3.5 py-1.5 text-body-sm font-semibold disabled:opacity-40"
              >
                Analisar loudness ({max(@loudness.total - @loudness.measured, 0)})
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
              <div class="flex justify-end">
                <button class="rounded-md bg-primary px-3.5 py-1.5 text-body-sm font-semibold text-white">
                  Baixar
                </button>
              </div>
            </form>

            <div class="mt-2 flex items-center justify-between gap-3 border-t border-white/6 pt-2">
              <span class="text-body-sm text-ink-secondary">
                Pendentes de enriquecimento: {@youtube_pending}
              </span>
              <button
                phx-click="enrich_youtube"
                disabled={enrich_running?(@enrich) or @youtube_pending == 0}
                class="rounded-md border border-white/10 bg-input px-3 py-1.5 text-body-sm text-ink-secondary hover:text-ink disabled:opacity-40"
              >
                {if enrich_running?(@enrich),
                  do: "Enriquecendo…",
                  else: "Enriquecer pendentes (#{@youtube_pending})"}
              </button>
            </div>

            <div
              :if={enrich_running?(@enrich)}
              class="mt-2 rounded-lg border border-white/8 bg-base px-3 py-2"
            >
              <p class="text-body-sm text-ink-secondary">{enrich_label(@enrich)}</p>
              <div class="mt-1.5 h-1.5 w-full rounded-full bg-white/5">
                <div
                  class="h-full rounded-full bg-primary transition-[width]"
                  style={"width:#{enrich_pct(@enrich)}%"}
                />
              </div>
            </div>

            <p :if={@youtube_note} class="mt-1.5 text-caption text-ink-muted">{@youtube_note}</p>
            <p class="mt-1 text-caption text-ink-faint">
              Baixar é offline (não gasta cota). Enriquecer chama o Soundcharts (cota) e gera sugestões na Central de Revisão.
            </p>
            <.link
              navigate={~p"/jobs"}
              class="mt-1 inline-block text-caption text-primary hover:underline"
            >
              Ver downloads em andamento em Jobs →
            </.link>
          </.panel>

          <div class="grid grid-cols-1 gap-5 lg:grid-cols-2 2xl:grid-cols-4">
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
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div class="flex flex-wrap items-center gap-1.5">
                <button
                  :for={f <- @folders}
                  type="button"
                  phx-click="select_folder"
                  phx-value-folder={f.key}
                  class={[
                    "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[12px] font-semibold transition-colors",
                    f.key == @gaps_folder && "border-primary/60 bg-primary/15 text-ink",
                    f.key != @gaps_folder && "border-white/8 text-ink-muted hover:text-ink"
                  ]}
                >
                  <span class="size-2 rounded-full" style={"background:#{folder_color(f.key)}"} />
                  {f.display_name}
                  <span class={[
                    "rounded-full px-1.5 text-[10px] font-bold tabular-nums",
                    (Map.get(@gap_counts, f.key, 0) > 0 && "bg-primary/25 text-primary") ||
                      "text-ink-faint bg-white/8"
                  ]}>
                    {Map.get(@gap_counts, f.key, 0)}
                  </span>
                </button>
              </div>
              <button
                type="button"
                phx-click="fetch_gaps"
                disabled={@recommending? or is_nil(@gaps_folder)}
                class="inline-flex shrink-0 items-center gap-2 rounded-md bg-primary px-3.5 py-1.5 text-body-sm font-semibold text-white transition-opacity disabled:opacity-50"
              >
                <span
                  :if={@recommending?}
                  class="size-2 animate-pulse rounded-full bg-white/90"
                  aria-hidden="true"
                ></span>
                {if @recommending?, do: "Gerando…", else: "Buscar lacunas (IA)"}
              </button>
            </div>

            <p class="mt-2 text-caption text-ink-faint">
              Sugestões de faixas que faltam nesta pasta, geradas pela IA (não gasta cota). Ficam salvas aqui até você baixar ou dispensar.
            </p>

            <div :if={@recs != []} class="mt-3 grid gap-2 lg:grid-cols-2">
              <.rec_row :for={rec <- @recs} rec={rec} />
            </div>

            <div
              :if={@recs == [] and @recommending?}
              class="mt-3 flex items-center gap-2 rounded-lg border border-primary/25 bg-primary/8 px-3 py-3 text-body-sm text-ink-secondary"
            >
              <span class="size-2.5 animate-pulse rounded-full bg-primary" aria-hidden="true"></span>
              Gerando sugestões com a IA… isso pode levar alguns segundos.
            </div>

            <p
              :if={@recs == [] and not @recommending?}
              class="mt-3 rounded-lg border border-dashed border-white/8 px-3 py-4 text-center text-body-sm text-ink-faint"
            >
              Nenhuma sugestão salva para esta pasta. Clique em <span class="text-ink-secondary">Buscar lacunas (IA)</span>.
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

  @doc """
  One persisted AI recommendation (a folder gap or a track match): `artist — song`,
  the AI's reason, and the YouTube search / download / dismiss actions. Imported
  rows wear a subtle "baixada" tag so the history reads at a glance.
  """
  attr :rec, :map, required: true

  def rec_row(assigns) do
    ~H"""
    <div class={[
      "group rounded-lg border px-3 py-2.5 transition-colors",
      if(@rec.status == :imported,
        do: "border-green/25 bg-green/5",
        else: "border-white/6 bg-base hover:border-white/12"
      )
    ]}>
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <p class="truncate text-body font-medium">
            {@rec.artist} <span class="text-ink-faint">—</span> {@rec.song}
          </p>
          <p :if={@rec.reason} class="mt-0.5 text-caption text-ink-muted">{@rec.reason}</p>
        </div>
        <span
          :if={@rec.status == :imported}
          class="bg-token-chip inline-flex shrink-0 items-center gap-1 rounded-xs px-[7px] py-[2px] text-[9.5px] font-bold uppercase tracking-wide"
          style="--c:#5ad1a0"
        >
          ✓ baixada
        </span>
      </div>

      <div class="mt-2 flex flex-wrap items-center gap-1.5">
        <a
          href={Repertoire.youtube_search_url(@rec)}
          target="_blank"
          rel="noopener"
          class="inline-flex items-center gap-1 rounded-md border border-white/10 bg-input px-2.5 py-1 text-[11px] text-ink-secondary transition-colors hover:text-ink"
        >
          Buscar no YouTube <span class="text-ink-faint" aria-hidden="true">↗</span>
        </a>
        <button
          type="button"
          phx-click="download_rec"
          phx-value-id={@rec.id}
          class="inline-flex items-center gap-1 rounded-md bg-primary/15 px-2.5 py-1 text-[11px] font-semibold text-primary transition-colors hover:bg-primary/25"
        >
          ↓ {if @rec.status == :imported, do: "Baixar de novo", else: "Baixar"}
        </button>
        <button
          type="button"
          phx-click="dismiss_rec"
          phx-value-id={@rec.id}
          class="ml-auto rounded-md px-2.5 py-1 text-[11px] text-ink-muted transition-colors hover:text-coral"
        >
          Dispensar
        </button>
      </div>
    </div>
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
