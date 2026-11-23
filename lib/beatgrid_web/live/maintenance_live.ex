defmodule BeatgridWeb.MaintenanceLive do
  @moduledoc "Library-wide audio preparation, metadata enrichment and database backups."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.{Backup, Dashboard, Integrations}

  @commands %{
    "analyze_library" => :analyze_library,
    "analyze_loudness" => :analyze_loudness,
    "apply_gain" => :apply_gain,
    "map_markers" => :map_markers,
    "remap_markers" => :remap_markers,
    "db_backup" => :db_backup,
    "enrich_youtube" => :enrich_youtube,
    "enrich_rare" => :enrich_rare
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Dashboard.subscribe_maintenance()

    {:ok, assign(socket, Dashboard.maintenance_snapshot())}
  end

  @impl true
  def handle_event("restore_gain_backup", _params, socket) do
    {:noreply,
     apply_result(socket, Dashboard.run({:restore_gain_backup, socket.assigns.gain_undo_batch}))}
  end

  def handle_event(event, _params, socket) when is_map_key(@commands, event) do
    {:noreply, apply_result(socket, Dashboard.run(Map.fetch!(@commands, event)))}
  end

  @impl true
  def handle_info({tick}, socket)
      when tick in [:analysis_tick, :loudness_tick, :markers_tick, :backup_tick, :youtube_tick] do
    {:noreply, apply_result(socket, Dashboard.refresh(tick))}
  end

  def handle_info({:enrich_progress, _payload} = event, socket) do
    {:noreply, apply_result(socket, Dashboard.refresh(event))}
  end

  defp apply_result(socket, {:ok, assigns}), do: assign(socket, assigns)
  defp apply_result(socket, :ignore), do: socket
  defp apply_result(socket, {:flash, level, message}), do: put_flash(socket, level, message)

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:manutencao} socket={@socket}>
      <header class="border-b border-white/6 bg-rail px-3 py-3 sm:px-6">
        <div class="mx-auto flex max-w-[1100px] flex-wrap items-center justify-between gap-3">
          <h1 class="text-[22px] font-semibold">Manutenção</h1>
          <div class="flex flex-wrap items-center gap-2">
            <.link
              id="maintenance-ajustes"
              navigate={~p"/ajustes"}
              class="rounded-md border border-white/10 bg-input px-3 py-2 text-body-sm font-semibold text-ink-secondary hover:text-ink"
            >
              Ajustes
            </.link>
            <.link
              navigate={~p"/jobs"}
              class="inline-flex items-center gap-2 rounded-md border border-white/10 bg-input px-3 py-2 text-body-sm font-semibold text-ink-secondary hover:text-ink"
            >
              Ver fila de tarefas <.icon name="hero-arrow-right-mini" class="size-4" />
            </.link>
          </div>
        </div>
      </header>

      <div class="mx-auto max-w-[1100px] space-y-5 px-3 py-5 sm:px-6">
        <.group id="maintenance-audio" title="Preparação de áudio">
          <.operation title="Análise de áudio local (BPM e tom)" id="maintenance-analysis">
            <.coverage_progress value={@analysis.analyzed} total={@analysis.total} label="analisadas" />
            <p :if={@analysis_note} role="status" class="text-body-sm text-ink-muted">
              {@analysis_note}
            </p>
            <:actions>
              <.action
                event="analyze_library"
                primary
                disabled={@analysis.analyzed >= @analysis.total}
              >
                Analisar faltantes ({max(@analysis.total - @analysis.analyzed, 0)})
              </.action>
            </:actions>
          </.operation>

          <.operation title="Marcadores de entrada, saída e seção" id="maintenance-markers">
            <.coverage_progress value={@markers.mapped} total={@markers.total} label="com marcadores" />
            <p :if={@markers_queue > 0} class="text-body-sm text-ink-secondary">
              <span class="font-mono tabular-nums">{@markers_queue}</span> na fila
            </p>
            <p :if={@markers_note} role="status" class="text-body-sm text-ink-muted">
              {@markers_note}
            </p>
            <:actions>
              <.action event="map_markers" disabled={@markers_unmapped == 0}>
                Mapear faltantes ({@markers_unmapped})
              </.action>
              <.action
                event="remap_markers"
                disabled={@markers_queue > 0}
                data-confirm="Remapear todas as faixas? Os marcadores manuais serão preservados e os automáticos serão recalculados."
              >
                {if @markers_queue > 0, do: "Mapeamento em andamento…", else: "Remapear tudo"}
              </.action>
            </:actions>
          </.operation>

          <.operation title="Loudness (LUFS)" id="maintenance-loudness">
            <.coverage_progress value={@loudness.measured} total={@loudness.total} label="medidas" />
            <p :if={@loudness_note} role="status" class="text-body-sm text-ink-muted">
              {@loudness_note}
            </p>
            <:actions>
              <.action event="analyze_loudness" disabled={@loudness.measured >= @loudness.total}>
                Medir loudness ({max(@loudness.total - @loudness.measured, 0)})
              </.action>
            </:actions>
          </.operation>

          <.operation title="Ajuste de ganho" id="maintenance-gain">
            <p class="text-body-sm text-ink-muted">
              Salva uma cópia do áudio original antes de aplicar o ganho e medir o volume de novo.
            </p>
            <p :if={@gain_note} role="status" class="text-body-sm text-ink-muted">
              {@gain_note}
            </p>
            <:actions>
              <.action event="apply_gain" disabled={@gain_pending == 0}>
                Aplicar ganho ({@gain_pending})
              </.action>
              <.action :if={@gain_undo_batch} event="restore_gain_backup">
                Desfazer último ajuste de ganho
              </.action>
            </:actions>
          </.operation>
        </.group>

        <.group id="maintenance-enrichment" title="Enriquecimento de metadados">
          <.operation title="Importações do YouTube" id="maintenance-youtube">
            <p class="text-body-sm text-ink-muted">
              Pendentes de enriquecimento:
              <span class="font-mono tabular-nums">{@youtube_pending}</span>
            </p>
            <p class="text-body-sm text-ink-muted">
              O enriquecimento usa a cota do Soundcharts e envia sugestões para a Revisão.
            </p>
            <.integration_gate key={:soundcharts} />
            <.enrich_progress :if={enrich_running?(@enrich)} progress={@enrich} />
            <:actions>
              <.action
                event="enrich_youtube"
                disabled={
                  enrich_running?(@enrich) or @youtube_pending == 0 or
                    not Integrations.configured?(:soundcharts)
                }
              >
                {if enrich_running?(@enrich),
                  do: "Enriquecendo…",
                  else: "Enriquecer pendentes (#{@youtube_pending})"}
              </.action>
            </:actions>
          </.operation>

          <.operation title="Faixas raras" id="maintenance-rare">
            <p class="text-body-sm text-ink-muted">
              Soundcharts não achou <span class="font-mono tabular-nums">{@rare_pending}</span>
              faixa(s).
              A análise local e a IA ajudam a classificá-las.
            </p>
            <.enrich_progress :if={enrich_running?(@enrich_rare)} progress={@enrich_rare} />
            <:actions>
              <.action
                event="enrich_rare"
                disabled={enrich_running?(@enrich_rare) or @rare_pending == 0}
              >
                {if enrich_running?(@enrich_rare),
                  do: "Enriquecendo raras…",
                  else: "Enriquecer raras (#{@rare_pending})"}
              </.action>
            </:actions>
          </.operation>

          <div class="space-y-2 py-3">
            <p :if={@youtube_note} role="status" class="text-body-sm text-ink-muted">
              {@youtube_note}
            </p>
            <div class="flex flex-wrap gap-x-4 gap-y-2 text-body-sm">
              <.link
                navigate={~p"/importados"}
                class="text-primary underline-offset-2 hover:underline"
              >
                Conferir links e importações
              </.link>
              <.link
                :if={@youtube_failed > 0}
                navigate={~p"/jobs?state=failed&worker=DownloadWorker"}
                class="text-coral underline-offset-2 hover:underline"
              >
                Ver <span class="font-mono tabular-nums">{@youtube_failed}</span>
                download(s) com falha
              </.link>
            </div>
          </div>
        </.group>

        <.group id="maintenance-backup" title="Backup da curadoria">
          <.operation title="Banco de dados" id="maintenance-database">
            <p class={["font-mono text-body-sm tabular-nums", backup_tone(@backup)]}>
              {backup_label(@backup)}
            </p>
            <p class="text-body-sm text-ink-muted">
              O backup diário (5h) guarda sets, marcadores manuais, avaliações e decisões de curadoria.
              As últimas <span class="font-mono tabular-nums">{@backup_keep}</span>
              cópias ficam em <code class="font-mono">_Backups/DB</code>.
            </p>
            <details :if={@backup} class="max-w-full text-body-sm text-ink-muted">
              <summary class="cursor-pointer text-primary">Comando para restaurar o backup</summary>
              <code class="mt-2 block break-all rounded-md bg-input p-2 font-mono text-ink-secondary">
                {Backup.restore_command(@backup)}
              </code>
            </details>
            <p :if={@backup_note} role="status" class="text-body-sm text-ink-muted">
              {@backup_note}
            </p>
            <:actions>
              <.action event="db_backup">Fazer backup agora</.action>
            </:actions>
          </.operation>
        </.group>
      </div>
    </.app_shell>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp group(assigns) do
    ~H"""
    <section
      id={@id}
      aria-labelledby={"#{@id}-title"}
      class="rounded-xl border border-white/8 bg-surface px-4 pt-3"
    >
      <h2 id={"#{@id}-title"} class="mb-2 text-[18px] font-semibold">{@title}</h2>
      <div class="divide-y divide-white/8">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true
  slot :actions, required: true

  defp operation(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-col gap-2 py-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4"
    >
      <div class="min-w-0 flex-1 space-y-1">
        <h3 class="text-body-lg font-semibold">{@title}</h3>
        {render_slot(@inner_block)}
      </div>
      <div class="flex flex-wrap items-center gap-2 sm:justify-end">{render_slot(@actions)}</div>
    </div>
    """
  end

  attr :event, :string, required: true
  attr :disabled, :boolean, default: false
  attr :primary, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true

  defp action(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      disabled={@disabled}
      class={[
        "rounded-md border px-3 py-2 text-body-sm font-semibold disabled:opacity-40",
        if(@primary,
          do: "border-transparent bg-primary-deep text-white",
          else: "border-white/10 bg-input text-ink-secondary hover:text-ink"
        )
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :value, :integer, required: true
  attr :total, :integer, required: true
  attr :label, :string, required: true

  defp coverage_progress(assigns) do
    ~H"""
    <p class="font-mono text-body-sm tabular-nums text-ink-muted">
      {@value}/{@total} {@label}
    </p>
    <div
      :if={@total > 0}
      role="progressbar"
      aria-label={"Faixas #{@label}"}
      aria-valuenow={@value}
      aria-valuemin="0"
      aria-valuemax={@total}
      class="h-1.5 max-w-sm rounded-full bg-white/5"
    >
      <div
        class="h-full rounded-full bg-primary motion-safe:transition-[width]"
        style={"width:#{round(@value / @total * 100)}%"}
      >
      </div>
    </div>
    """
  end

  attr :progress, :map, required: true

  defp enrich_progress(assigns) do
    ~H"""
    <div role="status" class="max-w-sm space-y-1 text-body-sm text-ink-secondary">
      <p>{enrich_label(@progress)}</p>
      <div aria-hidden="true" class="h-1.5 rounded-full bg-white/5">
        <div
          class="h-full rounded-full bg-primary motion-safe:transition-[width]"
          style={"width:#{enrich_pct(@progress)}%"}
        />
      </div>
    </div>
    """
  end

  defp backup_label(nil), do: "Nenhum backup criado"

  defp backup_label(%{at: at, size: size}) do
    hours = DateTime.diff(DateTime.utc_now(), at, :hour)
    age = if hours < 1, do: "agora há pouco", else: "há #{hours}h"
    "Último backup #{age} · #{Float.round(size / 1_048_576, 1)} MB"
  end

  defp backup_tone(nil), do: "text-amber"

  defp backup_tone(%{at: at}) do
    if DateTime.diff(DateTime.utc_now(), at, :hour) > 48, do: "text-amber", else: "text-ink-muted"
  end

  defp enrich_running?(%{status: status}),
    do: status in [:queued, :running, :refining, :finishing]

  defp enrich_running?(nil), do: false

  defp enrich_label(%{status: :queued}), do: "Enriquecendo · na fila"

  defp enrich_label(%{status: :refining, done: d, total: t}),
    do: "Refinando títulos com IA #{d}/#{t}"

  defp enrich_label(%{scope: "rare", status: :running, done: d, total: t}),
    do: "Classificando faixas raras #{d}/#{t}"

  defp enrich_label(%{status: :running, done: d, total: t}),
    do: "Buscando no Soundcharts #{d}/#{t}"

  defp enrich_label(%{status: :finishing}), do: "Reavaliando e classificando com IA"
  defp enrich_label(_enrich), do: "Enriquecendo…"

  defp enrich_pct(%{status: :finishing}), do: 100
  defp enrich_pct(%{done: d, total: t}) when is_integer(t) and t > 0, do: round(d / t * 100)
  defp enrich_pct(_enrich), do: 0
end
