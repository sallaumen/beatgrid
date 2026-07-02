defmodule BeatgridWeb.DashboardLive do
  @moduledoc "Painel — library KPIs, distribution charts, and AI repertoire gaps."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.{Dashboard, Repertoire}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Dashboard.subscribe()
    end

    {:ok,
     socket
     |> assign(Dashboard.snapshot())}
  end

  defp assign_gaps(socket, folder) do
    assign(socket, Dashboard.gaps(folder))
  end

  @impl true
  def handle_event("analyze_library", _params, socket) do
    {:noreply, apply_dashboard_result(socket, Dashboard.run(:analyze_library))}
  end

  def handle_event("map_markers", _params, socket) do
    {:noreply, apply_dashboard_result(socket, Dashboard.run(:map_markers))}
  end

  def handle_event("build_example_set", _params, socket) do
    {:noreply, apply_dashboard_result(socket, Dashboard.run(:build_example_set))}
  end

  def handle_event("analyze_loudness", _params, socket) do
    {:noreply, apply_dashboard_result(socket, Dashboard.run(:analyze_loudness))}
  end

  def handle_event("apply_gain", _params, socket) do
    {:noreply, apply_dashboard_result(socket, Dashboard.run(:apply_gain))}
  end

  def handle_event("restore_gain_backup", _params, socket) do
    {:noreply,
     apply_dashboard_result(
       socket,
       Dashboard.run({:restore_gain_backup, socket.assigns.gain_undo_batch})
     )}
  end

  def handle_event("download_youtube", %{"urls" => urls}, socket) do
    {:noreply, apply_dashboard_result(socket, Dashboard.run({:download_youtube, urls}))}
  end

  def handle_event("enrich_youtube", _params, socket) do
    {:noreply, apply_dashboard_result(socket, Dashboard.run(:enrich_youtube))}
  end

  def handle_event("enrich_rare", _params, socket) do
    {:noreply, apply_dashboard_result(socket, Dashboard.run(:enrich_rare))}
  end

  def handle_event("select_folder", %{"folder" => key}, socket) do
    {:noreply, assign_gaps(socket, key)}
  end

  def handle_event("fetch_gaps", _params, socket) do
    {:noreply,
     apply_dashboard_result(socket, Dashboard.run({:fetch_gaps, socket.assigns.gaps_folder}))}
  end

  def handle_event("download_rec", %{"id" => id}, socket) do
    result =
      Dashboard.run({:download_recommendation, id},
        folder: socket.assigns.gaps_folder,
        current_note: socket.assigns.youtube_note
      )

    {:noreply, apply_dashboard_result(socket, result)}
  end

  def handle_event("dismiss_rec", %{"id" => id}, socket) do
    {:noreply,
     apply_dashboard_result(
       socket,
       Dashboard.run({:dismiss_recommendation, id}, folder: socket.assigns.gaps_folder)
     )}
  end

  @impl true
  def handle_info({:analysis_tick}, socket) do
    {:noreply, apply_dashboard_result(socket, Dashboard.refresh(:analysis_tick))}
  end

  def handle_info({:loudness_tick}, socket) do
    {:noreply, apply_dashboard_result(socket, Dashboard.refresh(:loudness_tick))}
  end

  def handle_info({:youtube_tick}, socket) do
    {:noreply, apply_dashboard_result(socket, Dashboard.refresh(:youtube_tick))}
  end

  def handle_info({:enrich_progress, _payload} = event, socket),
    do: {:noreply, apply_dashboard_result(socket, Dashboard.refresh(event))}

  # Folder recommendation finished generating. Reload the persisted gaps and clear
  # the "Gerando…" state — but only for the folder currently on screen. Other
  # folders' ticks just clear the spinner.
  def handle_info({:recommend_progress, %{scope: "folder", key: key, status: :error}}, socket) do
    {:noreply,
     socket
     |> assign(recommending?: false)
     |> put_flash(:error, "A IA não conseguiu gerar as lacunas de #{key} — tente de novo.")}
  end

  def handle_info({:recommend_progress, %{scope: "folder", key: key, status: :done}}, socket) do
    if key == socket.assigns.gaps_folder do
      {:noreply, socket |> assign(recommending?: false) |> assign_gaps(key)}
    else
      {:noreply, assign(socket, recommending?: false)}
    end
  end

  def handle_info({:recommend_progress, _payload}, socket), do: {:noreply, socket}

  # --- helpers ---

  defp apply_dashboard_result(socket, {:ok, assigns}), do: assign(socket, assigns)
  defp apply_dashboard_result(socket, :ignore), do: socket

  defp apply_dashboard_result(socket, {:flash, level, message}),
    do: put_flash(socket, level, message)

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

  defp enrich_label(%{scope: "rare", status: :running, done: d, total: t}),
    do: "Enriquecendo raras (IA + análise) #{d}/#{t}…"

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
          <div class="mx-auto flex max-w-[1600px] flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <h2 class="text-[22px] font-semibold">Painel</h2>
              <p class="text-body-sm text-ink-muted">{@overview.total} faixas na biblioteca</p>
            </div>
            <div class="grid grid-cols-1 gap-2 sm:w-[520px] sm:grid-cols-3">
              <.status_pill
                label="Markers"
                value={@markers_unmapped}
                tone={if @markers_unmapped > 0, do: :alert, else: :ok}
              />
              <.status_pill
                label="Gain queue"
                value={@gain_pending}
                tone={if @gain_pending > 0, do: :alert, else: :ok}
              />
              <.status_pill
                label="YouTube queue"
                value={@youtube_pending}
                tone={if @youtube_pending > 0, do: :info, else: :ok}
              />
            </div>
          </div>
        </header>

        <div class="mx-auto max-w-[1600px] space-y-5 px-3 py-5 sm:px-6">
          <section
            id="dashboard-kpis"
            class="grid grid-cols-1 gap-3 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-6"
          >
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

          <div class="grid grid-cols-1 gap-5 xl:grid-cols-[minmax(0,1.25fr)_minmax(360px,0.75fr)]">
            <.panel id="dashboard-operations" title="Operações">
              <div class="rounded-lg border border-white/6 bg-base/45 p-2 sm:p-3">
                <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-col gap-1 text-body-sm sm:flex-row sm:items-center sm:justify-between">
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
                    class="w-full shrink-0 whitespace-normal break-words rounded-md bg-primary px-2 py-1.5 text-center text-body-sm font-semibold text-white disabled:opacity-40 sm:w-auto sm:px-3.5"
                  >
                    Analisar faltantes ({max(@analysis.total - @analysis.analyzed, 0)})
                  </button>
                </div>
              </div>

              <div class="mt-3 rounded-lg border border-white/6 bg-base/45 p-2 sm:p-3">
                <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-col gap-1 text-body-sm sm:flex-row sm:items-center sm:justify-between">
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
                    class="text-amber w-full shrink-0 whitespace-normal break-words rounded-md bg-amber/20 px-2 py-1.5 text-center text-body-sm font-semibold disabled:opacity-40 sm:w-auto sm:px-3.5"
                  >
                    Analisar loudness ({max(@loudness.total - @loudness.measured, 0)})
                  </button>
                </div>
              </div>

              <div class="mt-3 rounded-lg border border-white/6 bg-base/45 p-2 sm:p-3">
                <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
                  <div class="min-w-0 flex-1">
                    <span class="text-body-sm text-ink-secondary">Gain application</span>
                    <p class="mt-1 text-caption text-ink-muted">
                      Applies the measured LUFS gain to eligible files and remeasures them.
                    </p>
                  </div>
                  <button
                    phx-click="apply_gain"
                    disabled={@gain_pending == 0}
                    class="w-full shrink-0 whitespace-normal break-words rounded-md bg-amber/15 px-2 py-1.5 text-center text-body-sm font-semibold text-amber disabled:opacity-40 sm:w-auto sm:px-3.5"
                  >
                    Apply gain ({@gain_pending})
                  </button>
                  <button
                    :if={@gain_undo_batch}
                    phx-click="restore_gain_backup"
                    class="w-full shrink-0 whitespace-normal break-words rounded-md border border-amber/30 bg-input px-2 py-1.5 text-center text-body-sm font-semibold text-amber hover:bg-amber/10 sm:w-auto sm:px-3.5"
                  >
                    Restore gain backup
                  </button>
                </div>
              </div>

              <div class="mt-3 rounded-lg border border-white/6 bg-base/45 p-2 sm:p-3">
                <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
                  <div class="min-w-0 flex-1">
                    <span class="text-body-sm text-ink-secondary">Mapear marcadores da biblioteca</span>
                    <p class="mt-1 text-caption text-ink-muted">
                      Detecta intro/saída e seções (análise de áudio) nas faixas que ainda não têm
                      marcadores automáticos — deixa tudo pronto pra planejar e tocar sets.
                    </p>
                    <p :if={@markers_note} class="mt-1.5 text-caption text-ink-muted">
                      {@markers_note}
                    </p>
                  </div>
                  <button
                    phx-click="map_markers"
                    disabled={@markers_unmapped == 0}
                    class="w-full shrink-0 whitespace-normal break-words rounded-md bg-primary/15 px-2 py-1.5 text-center text-body-sm font-semibold text-primary disabled:opacity-40 sm:w-auto sm:px-3.5"
                  >
                    Mapear marcadores ({@markers_unmapped})
                  </button>
                </div>
              </div>

              <div class="mt-3 rounded-lg border border-white/6 bg-base/45 p-2 sm:p-3">
                <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
                  <div class="min-w-0 flex-1">
                    <span class="text-body-sm text-ink-secondary">Set de exemplo (Roots)</span>
                    <p class="mt-1 text-caption text-ink-muted">
                      Monta um set do Forró Roots, detecta intro/saída por análise e conecta as
                      faixas com transições — pronto pra tocar no autoplay (REC SET).
                    </p>
                  </div>
                  <button
                    phx-click="build_example_set"
                    class="w-full shrink-0 whitespace-normal break-words rounded-md border border-primary/40 bg-primary/10 px-2 py-1.5 text-center text-body-sm font-semibold text-primary hover:bg-primary/20 sm:w-auto sm:px-3.5"
                  >
                    ⛓ Montar set de exemplo
                  </button>
                </div>
              </div>
            </.panel>

            <.panel id="dashboard-imports" title="Importar do YouTube">
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

              <div class="mt-2 flex flex-col gap-3 border-t border-white/6 pt-2 sm:flex-row sm:items-center sm:justify-between">
                <span class="break-words text-body-sm text-ink-secondary">
                  Pendentes de enriquecimento: {@youtube_pending}
                </span>
                <button
                  phx-click="enrich_youtube"
                  disabled={
                    enrich_running?(@enrich) or @youtube_pending == 0 or
                      not Beatgrid.Integrations.configured?(:soundcharts)
                  }
                  class="w-full whitespace-normal break-words rounded-md border border-white/10 bg-input px-2 py-1.5 text-center text-body-sm text-ink-secondary hover:text-ink disabled:opacity-40 disabled:cursor-not-allowed sm:w-auto sm:px-3"
                >
                  {if enrich_running?(@enrich),
                    do: "Enriquecendo…",
                    else: "Enriquecer pendentes (#{@youtube_pending})"}
                </button>
                <.integration_gate key={:soundcharts} />
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

              <div class="mt-4 flex flex-col gap-3 border-t border-white/6 pt-2 sm:flex-row sm:items-center sm:justify-between">
                <span class="text-body-sm text-ink-secondary">
                  Soundcharts não achou / raras: {@rare_pending}
                </span>
                <button
                  phx-click="enrich_rare"
                  disabled={enrich_running?(@enrich_rare) or @rare_pending == 0}
                  class="w-full whitespace-normal break-words rounded-md border border-white/10 bg-input px-2 py-1.5 text-center text-body-sm text-ink-secondary hover:text-ink disabled:opacity-40 sm:w-auto sm:px-3"
                >
                  {if enrich_running?(@enrich_rare),
                    do: "Enriquecendo raras…",
                    else: "Enriquecer raras (IA + análise) (#{@rare_pending})"}
                </button>
              </div>

              <div
                :if={enrich_running?(@enrich_rare)}
                class="mt-2 rounded-lg border border-white/8 bg-base px-3 py-2"
              >
                <p class="text-body-sm text-ink-secondary">{enrich_label(@enrich_rare)}</p>
                <div class="mt-1.5 h-1.5 w-full rounded-full bg-white/5">
                  <div
                    class="h-full rounded-full bg-amber transition-[width]"
                    style={"width:#{enrich_pct(@enrich_rare)}%"}
                  />
                </div>
              </div>

              <p :if={@youtube_note} class="mt-1.5 text-caption text-ink-muted">{@youtube_note}</p>
              <p :if={@youtube_failed > 0} class="mt-1.5 text-caption text-coral">
                {@youtube_failed} download(s) falharam de vez — <.link
                  navigate={~p"/jobs"}
                  class="underline"
                >re-tentar ou limpar em Jobs</.link>.
              </p>
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
          </div>

          <div id="dashboard-insights" class="grid grid-cols-1 gap-5 lg:grid-cols-2 2xl:grid-cols-4">
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

          <.panel id="dashboard-gaps" title="Lacunas no repertório (IA)">
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

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: :info

  defp status_pill(assigns) do
    ~H"""
    <div class={["rounded-lg border px-3 py-2", status_pill_class(@tone)]}>
      <p class="truncate text-[10px] font-semibold uppercase text-ink-faint">{@label}</p>
      <p class="mt-0.5 font-mono text-[16px] font-semibold text-ink">{@value}</p>
    </div>
    """
  end

  defp status_pill_class(:ok), do: "border-green/20 bg-green/8"
  defp status_pill_class(:alert), do: "border-amber/35 bg-amber/10"
  defp status_pill_class(_tone), do: "border-primary/25 bg-primary/10"

  attr :id, :string, default: nil
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section id={@id} class="rounded-lg border border-white/6 bg-surface p-3 sm:p-4">
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
      <span class="w-16 shrink-0 truncate text-[12px] text-ink-secondary sm:w-28">{@label}</span>
      <div class="h-[7px] min-w-0 flex-1 rounded-full bg-white/5">
        <div class="h-full rounded-full" style={"width:#{pct(@value, @max)}%;background:#{@color}"}>
        </div>
      </div>
      <span class="w-6 shrink-0 text-right font-mono text-[11px] text-ink-muted sm:w-8">{@value}</span>
    </div>
    """
  end

  defp empty(assigns) do
    ~H"""
    <p class="text-body-sm text-ink-faint">Sem dados ainda.</p>
    """
  end
end
