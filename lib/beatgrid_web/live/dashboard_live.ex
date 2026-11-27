defmodule BeatgridWeb.DashboardLive do
  @moduledoc "Repertório — library KPIs, distribution charts, and AI repertoire gaps."
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
  def handle_event("select_folder", %{"folder" => key}, socket) do
    if Enum.any?(socket.assigns.folders, &(&1.key == key)) do
      {:noreply, assign_gaps(socket, key)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("fetch_gaps", _params, %{assigns: %{gaps_folder: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("fetch_gaps", _params, socket) do
    {:noreply,
     apply_dashboard_result(socket, Dashboard.run({:fetch_gaps, socket.assigns.gaps_folder}))}
  end

  def handle_event("dismiss_rec", %{"id" => id}, socket) do
    {:noreply,
     apply_dashboard_result(
       socket,
       Dashboard.run({:dismiss_recommendation, id}, folder: socket.assigns.gaps_folder)
     )}
  end

  @impl true
  def handle_info({:analysis_tick}, socket),
    do: {:noreply, assign(socket, :bpm, Dashboard.tempo_distribution())}

  def handle_info(
        {:recommend_progress, %{scope: "folder", key: folder, status: :running}},
        %{assigns: %{gaps_folder: folder}} = socket
      ),
      do: {:noreply, assign(socket, recommending?: true)}

  def handle_info(
        {:recommend_progress, %{scope: "folder", key: folder, status: :done}},
        %{assigns: %{gaps_folder: folder}} = socket
      ) do
    # The worker broadcasts before Oban marks the job complete.
    {:noreply, socket |> assign_gaps(folder) |> assign(recommending?: false)}
  end

  def handle_info(
        {:recommend_progress, %{scope: "folder", key: folder, status: :error}},
        %{assigns: %{gaps_folder: folder}} = socket
      ) do
    {:noreply,
     socket
     |> assign(recommending?: false)
     |> put_flash(:error, "A busca de sugestões falhou. Tente de novo.")}
  end

  def handle_info({:recommend_progress, _payload}, socket), do: {:noreply, socket}

  defp apply_dashboard_result(socket, {:ok, assigns}), do: assign(socket, assigns)

  defp apply_dashboard_result(socket, {:flash, level, message}),
    do: put_flash(socket, level, message)

  defp pct(0, _max), do: 0
  defp pct(_value, 0), do: 0
  defp pct(value, max), do: max(round(value / max * 100), 2)

  defp max_count([]), do: 0
  defp max_count(list), do: list |> Enum.map(fn {_k, v} -> v end) |> Enum.max()

  defp track_count(1), do: "1 faixa"
  defp track_count(total), do: "#{total} faixas"

  defp decade_label(d), do: "#{d}s"

  defp conf(by_confidence, level), do: Map.get(by_confidence, level, 0)

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:painel} socket={@socket}>
      <header class="border-b border-white/6 bg-rail px-3 py-3 sm:px-6">
        <div class="mx-auto flex max-w-[1600px] flex-wrap items-center justify-between gap-3">
          <h1 class="text-[22px] font-semibold">Repertório</h1>
          <div class="flex flex-wrap items-center gap-2">
            <a
              href="#dashboard-gaps"
              class="inline-flex items-center gap-1.5 rounded-md border border-primary/35 bg-primary/10 px-3 py-2 text-body-sm font-semibold text-primary-soft"
            >
              Lacunas <.icon name="hero-arrow-down" class="size-3.5" />
            </a>
            <.link
              id="repertoire-maintenance"
              navigate={~p"/manutencao"}
              class="inline-flex items-center gap-2 rounded-md border border-white/10 bg-input px-3 py-2 text-body-sm font-semibold text-ink-secondary hover:text-ink"
            >
              Manutenção da biblioteca <.icon name="hero-arrow-right-mini" class="size-4" />
            </.link>
          </div>
        </div>
      </header>

      <div class="mx-auto max-w-[1600px] space-y-5 px-3 py-5 sm:px-6">
        <section
          id="dashboard-kpis"
          aria-labelledby="dashboard-overview-title"
          class="rounded-lg border border-white/8 bg-surface px-3 py-3 sm:px-4"
        >
          <h2 id="dashboard-overview-title" class="mb-3 text-[18px] font-semibold">
            Panorama do acervo
          </h2>
          <dl class="grid grid-cols-3 gap-x-3 gap-y-3 sm:gap-4 xl:grid-cols-6">
            <.overview_stat label="Total" value={@overview.total} tone="text-primary" prominent />
            <.overview_stat label="Resolvidas" value={@overview.resolved} tone="text-green" />
            <.overview_stat
              label="Sem correspondência"
              value={@overview.unresolved}
              tone="text-amber"
            />
            <.overview_stat
              label="Truncadas"
              value={@overview.truncated}
              tone={if(@overview.truncated > 0, do: "text-coral", else: "text-ink")}
            />
            <.overview_stat
              label="Conf. alta"
              value={conf(@overview.by_confidence, :high)}
              tone="text-green"
            />
            <.overview_stat
              label="Conf. baixa"
              value={conf(@overview.by_confidence, :low)}
              tone="text-coral"
            />
          </dl>
        </section>

        <div id="dashboard-insights" class="grid grid-cols-1 gap-4 lg:grid-cols-2 2xl:grid-cols-4">
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

          <.panel title="Artistas mais presentes">
            <div :if={@artists != []} class="space-y-2">
              <.bar_row
                :for={{artist, n} <- @artists}
                label={artist}
                value={n}
                max={max_count(@artists)}
                color="var(--color-primary)"
              />
            </div>
            <.empty :if={@artists == []} />
          </.panel>

          <.panel title="Andamento (BPM)">
            <ul :if={@bpm != []} class="space-y-2" aria-label="Quantidade de faixas por andamento">
              <li :for={{bucket, count} <- @bpm}>
                <span class="sr-only">De {bucket} a menos de {bucket + 5} BPM, {track_count(count)}</span>
                <div aria-hidden="true">
                  <.bar_row
                    label={"#{bucket}–#{bucket + 4}"}
                    value={count}
                    max={max_count(@bpm)}
                    color="var(--color-primary)"
                    mono
                  />
                </div>
              </li>
            </ul>
            <.empty :if={@bpm == []} />
          </.panel>

          <.panel title="Décadas">
            <div :if={@decades != []} class="space-y-2">
              <.bar_row
                :for={{d, n} <- @decades}
                label={decade_label(d)}
                value={n}
                max={max_count(@decades)}
                color="var(--color-info)"
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
                aria-pressed={to_string(f.key == @gaps_folder)}
                class={[
                  "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[12px] font-semibold transition-colors",
                  f.key == @gaps_folder && "border-primary/60 bg-primary/15 text-ink",
                  f.key != @gaps_folder && "border-white/8 text-ink-muted hover:text-ink"
                ]}
              >
                <span class="size-2 rounded-full" style={"background:#{folder_color(f.key)}"} />
                {f.display_name}
                <span class={[
                  "rounded-full px-1.5 font-mono text-caption font-bold tabular-nums",
                  (Map.get(@gap_counts, f.key, 0) > 0 && "bg-primary/15 text-primary") ||
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
              class="inline-flex shrink-0 items-center gap-2 rounded-md bg-primary-deep px-3.5 py-1.5 text-body-sm font-semibold text-white transition-opacity disabled:opacity-50"
            >
              <span
                :if={@recommending?}
                class="size-2 rounded-full bg-white/90 motion-safe:animate-pulse"
                aria-hidden="true"
              ></span>
              {if @recommending?, do: "Gerando…", else: "Buscar lacunas (IA)"}
            </button>
          </div>

          <p class="mt-2 text-caption text-ink-faint">
            As sugestões ficam salvas por pasta. Confira as versões antes de importar uma faixa.
          </p>

          <div :if={@recs != []} class="mt-3 grid gap-2 lg:grid-cols-2">
            <.rec_row :for={rec <- @recs} rec={rec} />
          </div>

          <div
            :if={@recommending?}
            role="status"
            class="mt-3 flex items-center gap-2 rounded-lg border border-primary/25 bg-primary/8 px-3 py-3 text-body-sm text-ink-secondary"
          >
            Gerando sugestões com a IA… isso pode levar alguns segundos.
          </div>

          <p
            :if={not is_nil(@gaps_folder) and @recs == [] and not @recommending?}
            class="mt-3 rounded-lg border border-dashed border-white/8 px-3 py-4 text-center text-body-sm text-ink-faint"
          >
            Nenhuma sugestão salva para esta pasta. Clique em <span class="text-ink-secondary">Buscar lacunas (IA)</span>.
          </p>
          <p :if={is_nil(@gaps_folder)} class="mt-3 text-body-sm text-ink-muted">
            Cadastre uma pasta em
            <.link navigate={~p"/generos"} class="text-primary underline">Gêneros</.link>
            para buscar sugestões.
          </p>
        </.panel>
      </div>
    </.app_shell>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, default: "text-ink"
  attr :prominent, :boolean, default: false

  defp overview_stat(assigns) do
    ~H"""
    <div class="flex min-w-0 flex-col justify-between gap-1 lg:border-white/8 lg:[&:not(:first-child)]:border-l lg:[&:not(:first-child)]:pl-4">
      <dt class="text-caption font-semibold uppercase tracking-wider text-ink-muted">{@label}</dt>
      <dd class={[
        "font-mono font-semibold leading-tight tabular-nums",
        @tone,
        if(@prominent, do: "text-[25px]", else: "text-[18px]")
      ]}>
        {@value}
      </dd>
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section
      id={@id}
      class="min-w-0 scroll-mt-4 rounded-lg border border-white/6 bg-surface p-3 sm:p-4"
    >
      <h2 class="mb-3 text-[18px] font-semibold">{@title}</h2>
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
          <p class="break-words text-body font-medium">
            {@rec.artist} <span class="text-ink-faint">—</span> {@rec.song}
          </p>
          <p :if={@rec.reason} class="mt-0.5 text-caption text-ink-muted">{@rec.reason}</p>
        </div>
        <span
          :if={@rec.status == :imported}
          class="bg-token-chip inline-flex shrink-0 items-center gap-1 rounded-xs px-[7px] py-[2px] text-[9.5px] font-bold uppercase tracking-wide"
          style="--c:var(--color-green)"
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
        <.link
          navigate={~p"/importados?recomendacao=#{@rec.id}"}
          class="inline-flex items-center rounded-md bg-primary/15 px-2.5 py-1 text-body-sm font-semibold text-primary-soft"
        >
          Conferir versões
        </.link>
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
  attr :color, :string, default: "var(--color-primary)"

  attr :mono, :boolean, default: false

  defp bar_row(assigns) do
    ~H"""
    <div class="grid grid-cols-[minmax(0,2fr)_minmax(0,3fr)_auto] items-center gap-2.5">
      <span
        title={@label}
        class={[
          "min-w-0 break-words text-body text-ink-secondary",
          @mono && "font-mono"
        ]}
      >
        {@label}
      </span>
      <div aria-hidden="true" class="h-[7px] min-w-0 rounded-full bg-white/5">
        <div class="h-full rounded-full" style={"width:#{pct(@value, @max)}%;background:#{@color}"}>
        </div>
      </div>
      <span class="min-w-7 shrink-0 text-right font-mono text-body-sm tabular-nums text-ink-muted">{@value}</span>
    </div>
    """
  end

  defp empty(assigns) do
    ~H"""
    <p class="text-body-sm text-ink-faint">Sem dados ainda.</p>
    """
  end
end
