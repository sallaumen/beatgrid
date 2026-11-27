defmodule BeatgridWeb.DashboardLive do
  @moduledoc "Repertório — library KPIs, distribution charts, and AI repertoire gaps."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI
  import BeatgridWeb.RecommendationComponents, only: [rec_row: 1]

  alias Beatgrid.Dashboard

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
  def handle_params(params, _uri, socket) do
    key = params["genero"]
    folders = socket.assigns.folders

    folder =
      if Enum.any?(folders, &(&1.key == key)),
        do: key,
        else: folders |> List.first() |> then(&(&1 && &1.key))

    if folder == socket.assigns.gaps_folder,
      do: {:noreply, socket},
      else: {:noreply, assign_gaps(socket, folder)}
  end

  defp folder_path(key), do: ~p"/painel?genero=#{key}" <> "#dashboard-gaps"

  @impl true
  def handle_event("select_folder", %{"folder" => key}, socket) do
    if Enum.any?(socket.assigns.folders, &(&1.key == key)) do
      {:noreply, push_patch(socket, to: folder_path(key))}
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
    do: {:noreply, assign(socket, bpm: Dashboard.tempo_distribution())}

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

  # Other folders' completions update the overview counts without touching the
  # selection or the current folder's in-flight status.
  def handle_info({:recommend_progress, %{scope: "folder", status: :done}}, socket) do
    %{gap_counts: counts} = Dashboard.gaps(socket.assigns.gaps_folder)
    {:noreply, assign(socket, gap_counts: counts)}
  end

  def handle_info({:recommend_progress, _payload}, socket), do: {:noreply, socket}

  defp apply_dashboard_result(socket, {:ok, assigns}), do: assign(socket, assigns)

  defp apply_dashboard_result(socket, {:flash, level, message}),
    do: put_flash(socket, level, message)

  defp pct(0, _max), do: 0
  defp pct(_value, 0), do: 0
  defp pct(value, max), do: max(round(value / max * 100), 2)

  defp max_count(list), do: list |> Enum.map(fn {_k, v} -> v end) |> Enum.max(fn -> 0 end)

  defp decade_label(d), do: "#{d}s"

  defp conf(by_confidence, level), do: Map.get(by_confidence, level, 0)

  defp saved_label(1), do: "1 sugestão salva"
  defp saved_label(count), do: "#{count} sugestões salvas"

  @impl true
  def render(assigns) do
    {imported, pending} = Enum.split_with(assigns.recs, &(&1.status == :imported))
    folders_by_key = Map.new(assigns.folders, &{&1.key, &1})

    assigns =
      assign(assigns,
        pending: pending,
        imported: imported,
        folders_by_key: folders_by_key,
        selected_folder: folders_by_key[assigns.gaps_folder]
      )

    ~H"""
    <.app_shell flash={@flash} active={:painel} socket={@socket}>
      <header class="border-b border-white/6 bg-rail">
        <div class="mx-auto flex max-w-[1600px] flex-wrap items-center justify-between gap-3 px-3 py-3 sm:px-6">
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

        <div
          id="dashboard-insights"
          class="grid grid-cols-1 items-start gap-4 lg:grid-cols-2 2xl:grid-cols-[minmax(0,1.45fr)_minmax(0,1fr)_minmax(0,1.8fr)_minmax(0,0.75fr)]"
        >
          <.panel id="dashboard-genres" title="Distribuição por gênero">
            <div :if={@genres != []}>
              <p class="mb-2 text-body-sm text-ink-muted">
                Faixas do acervo e sugestões salvas para cada gênero.
              </p>
              <ul class="divide-y divide-white/6">
                <li
                  :for={{key, n} <- @genres}
                  class="grid min-w-0 grid-cols-[minmax(0,1fr)_auto] items-center gap-2 py-1"
                >
                  <% folder = @folders_by_key[key] %>
                  <.bar_row
                    label={if folder, do: folder.display_name, else: key}
                    value={n}
                    max={max_count(@genres)}
                    color={folder_color(folder || %{key: key})}
                    wide_label
                  />
                  <.link
                    :if={folder}
                    patch={folder_path(key)}
                    aria-label={"Lacunas de #{folder.display_name}: #{saved_label(Map.get(@gap_counts, key, 0))}"}
                    class="inline-flex min-h-8 shrink-0 items-center justify-end gap-1 rounded-md px-1.5 py-1 text-body-sm font-medium text-primary-soft hover:bg-input hover:underline"
                  >
                    Lacunas
                    <span class="font-mono tabular-nums">({Map.get(@gap_counts, key, 0)})</span>
                    <.icon name="hero-arrow-right-mini" class="size-4 shrink-0" />
                  </.link>
                </li>
              </ul>
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
                wide_label
              />
            </div>
            <.empty :if={@artists == []} />
          </.panel>

          <.panel id="dashboard-tempo" title="Andamento (BPM)">
            <ol :if={@bpm != []} class="lg:columns-2 lg:gap-3">
              <li
                :for={{bucket, count} <- @bpm}
                aria-label={"De #{bucket} a menos de #{bucket + 5} BPM, #{count} #{if count == 1, do: "faixa", else: "faixas"}"}
                class="mb-2 break-inside-avoid"
              >
                <.bar_row
                  label={"#{bucket}–<#{bucket + 5}"}
                  value={count}
                  max={max_count(@bpm)}
                  color="var(--color-primary)"
                  mono
                />
              </li>
            </ol>
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
          <div
            :if={@folders != []}
            role="group"
            aria-label="Gênero das sugestões"
            class="flex flex-wrap items-center gap-1.5"
          >
            <button
              :for={f <- @folders}
              type="button"
              phx-click="select_folder"
              phx-value-folder={f.key}
              aria-pressed={to_string(f.key == @gaps_folder)}
              aria-label={"#{f.display_name}: #{saved_label(Map.get(@gap_counts, f.key, 0))}"}
              class={[
                "inline-flex min-w-0 max-w-full items-center gap-1.5 rounded-full border px-2.5 py-1.5 text-body font-semibold transition-colors",
                f.key == @gaps_folder && "border-primary/60 bg-primary/15 text-ink",
                f.key != @gaps_folder && "border-white/8 text-ink-muted hover:text-ink"
              ]}
            >
              <span
                class="size-2 shrink-0 rounded-full"
                style={"background:#{folder_color(f)}"}
                aria-hidden="true"
              />
              <span class="min-w-0 break-words text-left">{f.display_name}</span>
              <span class={[
                "shrink-0 rounded-full px-1.5 font-mono text-caption font-bold tabular-nums",
                (Map.get(@gap_counts, f.key, 0) > 0 && "bg-primary/15 text-primary") ||
                  "text-ink-muted bg-white/8"
              ]}>
                {Map.get(@gap_counts, f.key, 0)}
              </span>
            </button>
          </div>

          <div
            :if={@selected_folder}
            id="gaps-scope"
            class="mt-4 flex flex-wrap items-center justify-between gap-3 border-y border-white/8 py-3"
          >
            <div class="min-w-0">
              <h3 class="flex items-start gap-2 text-body-lg font-semibold text-ink">
                <span
                  class="mt-1 size-2.5 shrink-0 rounded-full"
                  style={"background:#{folder_color(@selected_folder)}"}
                  aria-hidden="true"
                />
                <span class="min-w-0 break-words">{@selected_folder.display_name}</span>
              </h3>
              <p class="mt-1 text-body text-ink-secondary">
                <span class="font-mono tabular-nums">{length(@pending)}</span>
                para conferir <span class="px-1 text-ink-muted">·</span>
                <span class="font-mono tabular-nums">{length(@imported)}</span>
                {if length(@imported) == 1, do: "importada", else: "importadas"}
              </p>
            </div>
            <button
              type="button"
              phx-click="fetch_gaps"
              disabled={@recommending? or is_nil(@gaps_folder)}
              class="inline-flex shrink-0 items-center gap-2 rounded-md bg-primary-deep px-3 py-2 text-body font-semibold text-white transition-opacity disabled:opacity-50"
            >
              <span
                :if={@recommending?}
                class="size-2 rounded-full bg-white/90 motion-safe:animate-pulse"
                aria-hidden="true"
              ></span>
              {if @recommending?, do: "Gerando…", else: "Buscar lacunas (IA)"}
            </button>
          </div>

          <div
            :if={@recommending?}
            role="status"
            class="mt-3 flex items-center gap-2 rounded-lg border border-primary/25 bg-primary/8 px-3 py-3 text-body text-ink-secondary"
          >
            Gerando sugestões com a IA… isso pode levar alguns segundos.
          </div>

          <section
            :if={@pending != []}
            id="gaps-pending"
            aria-labelledby="gaps-pending-title"
            class="mt-4"
          >
            <h3 id="gaps-pending-title" class="text-body-lg font-semibold">Para conferir</h3>
            <p class="mt-1 text-body-sm text-ink-muted">
              Confira as versões antes de importar uma faixa.
            </p>
            <div class="mt-2 grid gap-2 lg:grid-cols-2">
              <.rec_row :for={rec <- @pending} rec={rec} />
            </div>
          </section>

          <p
            :if={not is_nil(@gaps_folder) and @pending == [] and not @recommending?}
            class="mt-4 rounded-lg border border-dashed border-white/10 px-3 py-4 text-body text-ink-secondary"
          >
            {if @imported == [],
              do: "Nenhuma sugestão salva para esta pasta.",
              else: "Nenhuma sugestão pendente para esta pasta."}
          </p>

          <details :if={@imported != []} id="gaps-imported" class="mt-4 border-t border-white/8 pt-3">
            <summary class="cursor-pointer rounded-md py-2 text-body-lg font-semibold text-ink-secondary hover:text-ink">
              Já importadas
              <span class="font-mono text-body font-normal text-ink-muted">({length(@imported)})</span>
            </summary>
            <div class="mt-2 grid gap-2 lg:grid-cols-2">
              <.rec_row :for={rec <- @imported} rec={rec} />
            </div>
          </details>

          <p :if={is_nil(@gaps_folder)} class="mt-3 text-body text-ink-muted">
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
    <div class="flex min-w-0 flex-col justify-between gap-1 xl:border-white/8 xl:[&:not(:first-child)]:border-l xl:[&:not(:first-child)]:pl-4">
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

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :max, :integer, required: true
  attr :color, :string, default: "var(--color-primary)"

  attr :mono, :boolean, default: false
  attr :wide_label, :boolean, default: false

  defp bar_row(assigns) do
    ~H"""
    <div class={[
      "grid min-w-0 items-center gap-2",
      cond do
        @wide_label -> "grid-cols-[minmax(0,3fr)_minmax(1rem,2fr)_auto]"
        @mono -> "grid-cols-[4rem_minmax(0,1fr)_auto]"
        true -> "grid-cols-[minmax(0,2fr)_minmax(0,3fr)_auto]"
      end
    ]}>
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
